-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.
{-# LANGUAGE OverloadedStrings #-}

module Galley.API.Federation where

import Brig.Types.Connection (Relation (Accepted))
import Control.Lens (itraversed, (<.>))
import Data.ByteString.Conversion (toByteString')
import Data.Containers.ListUtils (nubOrd)
import Data.Domain (Domain)
import Data.Id
import Data.Json.Util
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map as Map
import Data.Map.Lens (toMapOf)
import Data.Qualified
import Data.Range (Range (fromRange))
import qualified Data.Set as Set
import Data.Singletons (SingI (..), demote, sing)
import qualified Data.Text.Lazy as LT
import Data.Time.Clock
import Galley.API.Action
import Galley.API.Error
import qualified Galley.API.Mapping as Mapping
import Galley.API.Message
import Galley.API.Push
import Galley.API.Util
import Galley.App
import qualified Galley.Data.Conversation as Data
import Galley.Effects
import qualified Galley.Effects.BrigAccess as E
import qualified Galley.Effects.ConversationStore as E
import qualified Galley.Effects.FireAndForget as E
import qualified Galley.Effects.MemberStore as E
import Galley.Options
import Galley.Types.Conversations.Members
import Galley.Types.UserList (UserList (UserList))
import Imports
import Polysemy
import Polysemy.Error
import Polysemy.Input
import Polysemy.Internal.Kind (Append)
import qualified Polysemy.TinyLog as P
import Servant (ServerT)
import Servant.API
import qualified System.Logger.Class as Log
import Wire.API.Conversation hiding (Member)
import qualified Wire.API.Conversation as Public
import Wire.API.Conversation.Action
import Wire.API.Conversation.Role
import qualified Wire.API.Conversation.Role as Public
import Wire.API.Error
import Wire.API.Error.Galley
import Wire.API.Event.Conversation
import Wire.API.Federation.API
import Wire.API.Federation.API.Common (EmptyResponse (..))
import Wire.API.Federation.API.Galley (ConversationUpdateResponse)
import qualified Wire.API.Federation.API.Galley as F
import Wire.API.Federation.Error
import Wire.API.Routes.Internal.Brig.Connection
import Wire.API.Routes.Named
import Wire.API.ServantProto
import Wire.API.User.Client (userClientMap)

type FederationAPI = "federation" :> FedApi 'Galley

-- | Convert a polysemy handler to an 'API' value.
federationSitemap :: ServerT FederationAPI (Sem GalleyEffects)
federationSitemap =
  Named @"on-conversation-created" onConversationCreated
    :<|> Named @"get-conversations" getConversations
    :<|> Named @"on-conversation-updated" onConversationUpdated
    :<|> Named @"leave-conversation" leaveConversation
    :<|> Named @"on-message-sent" onMessageSent
    :<|> Named @"send-message" sendMessage
    :<|> Named @"on-user-deleted-conversations" onUserDeleted
    :<|> Named @"update-conversation" updateConversation
    :<|> Named @"mls-welcome" mlsSendWelcome

onConversationCreated ::
  Members
    '[ BrigAccess,
       GundeckAccess,
       ExternalAccess,
       Input (Local ()),
       MemberStore,
       P.TinyLog
     ]
    r =>
  Domain ->
  F.NewRemoteConversation ConvId ->
  Sem r ()
onConversationCreated domain rc = do
  let qrc = fmap (toRemoteUnsafe domain) rc
  loc <- qualifyLocal ()
  let (localUserIds, _) = partitionQualified loc (map omQualifiedId (toList (F.rcNonCreatorMembers rc)))

  addedUserIds <-
    addLocalUsersToRemoteConv
      (F.rcCnvId qrc)
      (qUntagged (F.rcRemoteOrigUserId qrc))
      localUserIds

  let connectedMembers =
        Set.filter
          ( foldQualified
              loc
              (flip Set.member addedUserIds . tUnqualified)
              (const True)
              . omQualifiedId
          )
          (F.rcNonCreatorMembers rc)
  -- Make sure to notify only about local users connected to the adder
  let qrcConnected = qrc {F.rcNonCreatorMembers = connectedMembers}

  forM_ (fromNewRemoteConversation loc qrcConnected) $ \(mem, c) -> do
    let event =
          Event
            (qUntagged (F.rcCnvId qrcConnected))
            (qUntagged (F.rcRemoteOrigUserId qrcConnected))
            (F.rcTime qrcConnected)
            (EdConversation c)
    pushConversationEvent Nothing event (qualifyAs loc [qUnqualified . Public.memId $ mem]) []

getConversations ::
  Members '[ConversationStore, Input (Local ())] r =>
  Domain ->
  F.GetConversationsRequest ->
  Sem r F.GetConversationsResponse
getConversations domain (F.GetConversationsRequest uid cids) = do
  let ruid = toRemoteUnsafe domain uid
  loc <- qualifyLocal ()
  F.GetConversationsResponse
    . mapMaybe (Mapping.conversationToRemote (tDomain loc) ruid)
    <$> E.getConversations cids

getLocalUsers :: Domain -> NonEmpty (Qualified UserId) -> [UserId]
getLocalUsers localDomain = map qUnqualified . filter ((== localDomain) . qDomain) . toList

-- | Update the local database with information on conversation members joining
-- or leaving. Finally, push out notifications to local users.
onConversationUpdated ::
  Members
    '[ BrigAccess,
       GundeckAccess,
       ExternalAccess,
       Input (Local ()),
       MemberStore,
       P.TinyLog
     ]
    r =>
  Domain ->
  F.ConversationUpdate ->
  Sem r ()
onConversationUpdated requestingDomain cu = do
  loc <- qualifyLocal ()
  let rconvId = toRemoteUnsafe requestingDomain (F.cuConvId cu)
      qconvId = qUntagged rconvId

  -- Note: we generally do not send notifications to users that are not part of
  -- the conversation (from our point of view), to prevent spam from the remote
  -- backend. See also the comment below.
  (presentUsers, allUsersArePresent) <-
    E.selectRemoteMembers (F.cuAlreadyPresentUsers cu) rconvId

  -- Perform action, and determine extra notification targets.
  --
  -- When new users are being added to the conversation, we consider them as
  -- notification targets. Once we start checking connections before letting
  -- people being added, this will be safe against spam. However, if users that
  -- are not in the conversations are being removed or have their membership state
  -- updated, we do **not** add them to the list of targets, because we have no
  -- way to make sure that they are actually supposed to receive that notification.

  (mActualAction :: Maybe SomeConversationAction, extraTargets :: [UserId]) <- case F.cuAction cu of
    sca@(SomeConversationAction singTag action) -> case singTag of
      SConversationJoinTag -> do
        let ConversationJoin toAdd role = action
        let (localUsers, remoteUsers) = partitionQualified loc toAdd
        addedLocalUsers <- Set.toList <$> addLocalUsersToRemoteConv rconvId (F.cuOrigUserId cu) localUsers
        let allAddedUsers = map (qUntagged . qualifyAs loc) addedLocalUsers <> map qUntagged remoteUsers
        case allAddedUsers of
          [] -> pure (Nothing, []) -- If no users get added, its like no action was performed.
          (u : us) -> pure (Just (SomeConversationAction (sing @'ConversationJoinTag) (ConversationJoin (u :| us) role)), addedLocalUsers)
      SConversationLeaveTag -> do
        let localUsers = getLocalUsers (tDomain loc) action
        E.deleteMembersInRemoteConversation rconvId localUsers
        pure (Just sca, [])
      SConversationRemoveMembersTag -> do
        let localUsers = getLocalUsers (tDomain loc) action
        E.deleteMembersInRemoteConversation rconvId localUsers
        pure (Just sca, [])
      SConversationMemberUpdateTag ->
        pure (Just sca, [])
      SConversationDeleteTag -> do
        E.deleteMembersInRemoteConversation rconvId presentUsers
        pure (Just sca, [])
      SConversationRenameTag -> pure (Just sca, [])
      SConversationMessageTimerUpdateTag -> pure (Just sca, [])
      SConversationReceiptModeUpdateTag -> pure (Just sca, [])
      SConversationAccessDataTag -> pure (Just sca, [])

  unless allUsersArePresent $
    P.warn $
      Log.field "conversation" (toByteString' (F.cuConvId cu))
        . Log.field "domain" (toByteString' requestingDomain)
        . Log.msg
          ( "Attempt to send notification about conversation update \
            \to users not in the conversation" ::
              ByteString
          )

  -- Send notifications
  for_ mActualAction $ \(SomeConversationAction tag action) -> do
    let event = conversationActionToEvent tag (F.cuTime cu) (F.cuOrigUserId cu) qconvId action
        targets = nubOrd $ presentUsers <> extraTargets
    -- FUTUREWORK: support bots?
    pushConversationEvent Nothing event (qualifyAs loc targets) []

addLocalUsersToRemoteConv ::
  Members '[BrigAccess, MemberStore, P.TinyLog] r =>
  Remote ConvId ->
  Qualified UserId ->
  [UserId] ->
  Sem r (Set UserId)
addLocalUsersToRemoteConv remoteConvId qAdder localUsers = do
  connStatus <- E.getConnections localUsers (Just [qAdder]) (Just Accepted)
  let localUserIdsSet = Set.fromList localUsers
      connected = Set.fromList $ fmap csv2From connStatus
      unconnected = Set.difference localUserIdsSet connected
      connectedList = Set.toList connected

  -- FUTUREWORK: Consider handling the discrepancy between the views of the
  -- conversation-owning backend and the local backend
  unless (Set.null unconnected) $
    P.warn $
      Log.msg ("A remote user is trying to add unconnected local users to a remote conversation" :: Text)
        . Log.field "remote_user" (show qAdder)
        . Log.field "local_unconnected_users" (show unconnected)

  -- Update the local view of the remote conversation by adding only those local
  -- users that are connected to the adder
  E.createMembersInRemoteConversation remoteConvId connectedList
  pure connected

-- as of now this will not generate the necessary events on the leaver's domain
leaveConversation ::
  Members
    '[ ConversationStore,
       Error InvalidInput,
       ExternalAccess,
       FederatorAccess,
       GundeckAccess,
       Input (Local ()),
       Input UTCTime,
       MemberStore
     ]
    r =>
  Domain ->
  F.LeaveConversationRequest ->
  Sem r F.LeaveConversationResponse
leaveConversation requestingDomain lc = do
  let leaver :: Remote UserId = qTagUnsafe $ Qualified (F.lcLeaver lc) requestingDomain
  lcnv <- qualifyLocal (F.lcConvId lc)

  res <-
    runError
      . mapToRuntimeError @'ConvNotFound F.RemoveFromConversationErrorNotFound
      . mapToRuntimeError @('ActionDenied 'LeaveConversation) F.RemoveFromConversationErrorRemovalNotAllowed
      . mapToRuntimeError @'InvalidOperation F.RemoveFromConversationErrorRemovalNotAllowed
      . mapError @NoChanges (const F.RemoveFromConversationErrorUnchanged)
      $ do
        (conv, _self) <- getConversationAndMemberWithError @'ConvNotFound (qUntagged leaver) lcnv
        update <- updateLocalConversationWithRemoteUser SConversationLeaveTag lcnv leaver (pure (qUntagged leaver))
        pure (update, conv)

  case res of
    Left err -> pure $ F.LeaveConversationResponse (Left err)
    Right (_update, conv) -> do
      let action = pure (qUntagged leaver)

      let remotes = filter ((== tDomain leaver) . tDomain) (rmId <$> Data.convRemoteMembers conv)
      let botsAndMembers = BotsAndMembers mempty (Set.fromList remotes) mempty
      _event <- notifyConversationAction SConversationLeaveTag (qUntagged leaver) Nothing lcnv botsAndMembers action

      pure $ F.LeaveConversationResponse (Right ())
  where

-- FUTUREWORK: report errors to the originating backend
-- FUTUREWORK: error handling for missing / mismatched clients
onMessageSent ::
  Members '[GundeckAccess, ExternalAccess, MemberStore, Input (Local ()), P.TinyLog] r =>
  Domain ->
  F.RemoteMessage ConvId ->
  Sem r ()
onMessageSent domain rmUnqualified = do
  let rm = fmap (toRemoteUnsafe domain) rmUnqualified
      convId = qUntagged $ F.rmConversation rm
      msgMetadata =
        MessageMetadata
          { mmNativePush = F.rmPush rm,
            mmTransient = F.rmTransient rm,
            mmNativePriority = F.rmPriority rm,
            mmData = F.rmData rm
          }
      recipientMap = userClientMap $ F.rmRecipients rm
      msgs = toMapOf (itraversed <.> itraversed) recipientMap
  (members, allMembers) <-
    E.selectRemoteMembers (Map.keys recipientMap) (F.rmConversation rm)
  unless allMembers $
    P.warn $
      Log.field "conversation" (toByteString' (qUnqualified convId))
        Log.~~ Log.field "domain" (toByteString' (qDomain convId))
        Log.~~ Log.msg
          ( "Attempt to send remote message to local\
            \ users not in the conversation" ::
              ByteString
          )
  localMembers <- sequence $ Map.fromSet mkLocalMember (Set.fromList members)
  loc <- qualifyLocal ()
  void $
    sendLocalMessages
      loc
      (F.rmTime rm)
      (F.rmSender rm)
      (F.rmSenderClient rm)
      Nothing
      (Just convId)
      localMembers
      msgMetadata
      msgs
  where
    -- FUTUREWORK: https://wearezeta.atlassian.net/browse/SQCORE-875
    mkLocalMember :: UserId -> Sem r LocalMember
    mkLocalMember m =
      pure $
        LocalMember
          { lmId = m,
            lmService = Nothing,
            lmStatus = defMemberStatus,
            lmConvRoleName = Public.roleNameWireMember,
            lmMLSClients = Set.empty
          }

sendMessage ::
  Members
    '[ BrigAccess,
       ClientStore,
       ConversationStore,
       Error InvalidInput,
       FederatorAccess,
       GundeckAccess,
       Input (Local ()),
       Input Opts,
       Input UTCTime,
       ExternalAccess,
       MemberStore,
       TeamStore,
       P.TinyLog
     ]
    r =>
  Domain ->
  F.MessageSendRequest ->
  Sem r F.MessageSendResponse
sendMessage originDomain msr = do
  let sender = Qualified (F.msrSender msr) originDomain
  msg <- either throwErr pure (fromProto (fromBase64ByteString (F.msrRawMessage msr)))
  lcnv <- qualifyLocal (F.msrConvId msr)
  F.MessageSendResponse <$> postQualifiedOtrMessage User sender Nothing lcnv msg
  where
    throwErr = throw . InvalidPayload . LT.pack

onUserDeleted ::
  Members
    '[ ConversationStore,
       FederatorAccess,
       FireAndForget,
       ExternalAccess,
       GundeckAccess,
       Input (Local ()),
       Input UTCTime,
       MemberStore
     ]
    r =>
  Domain ->
  F.UserDeletedConversationsNotification ->
  Sem r EmptyResponse
onUserDeleted origDomain udcn = do
  let deletedUser = toRemoteUnsafe origDomain (F.udcvUser udcn)
      untaggedDeletedUser = qUntagged deletedUser
      convIds = F.udcvConversations udcn

  E.spawnMany $
    fromRange convIds <&> \c -> do
      lc <- qualifyLocal c
      mconv <- E.getConversation c
      E.deleteMembers c (UserList [] [deletedUser])
      for_ mconv $ \conv -> do
        when (isRemoteMember deletedUser (Data.convRemoteMembers conv)) $
          case Data.convType conv of
            -- No need for a notification on One2One conv as the user is being
            -- deleted and that notification should suffice.
            Public.One2OneConv -> pure ()
            -- No need for a notification on Connect Conv as there should be no
            -- other user in the conv.
            Public.ConnectConv -> pure ()
            -- The self conv cannot be on a remote backend.
            Public.SelfConv -> pure ()
            Public.RegularConv -> do
              let action = pure untaggedDeletedUser
                  botsAndMembers = convBotsAndMembers conv
              void $ notifyConversationAction (sing @'ConversationLeaveTag) untaggedDeletedUser Nothing lc botsAndMembers action
  pure EmptyResponse

updateConversation ::
  forall r.
  ( Members
      '[ BrigAccess,
         CodeStore,
         BotAccess,
         FireAndForget,
         Error FederationError,
         Error InvalidInput,
         ExternalAccess,
         FederatorAccess,
         Error InternalError,
         GundeckAccess,
         Input Opts,
         Input UTCTime,
         LegalHoldStore,
         MemberStore,
         TeamStore,
         ConversationStore,
         Input (Local ())
       ]
      r
  ) =>
  -- |
  Domain ->
  -- |
  F.ConversationUpdateRequest ->
  Sem r ConversationUpdateResponse
updateConversation origDomain updateRequest = do
  loc <- qualifyLocal ()
  let rusr = toRemoteUnsafe origDomain (F.curUser updateRequest)
      lcnv = qualifyAs loc (F.curConvId updateRequest)

  mkResponse $ case F.curAction updateRequest of
    SomeConversationAction tag action ->
      case tag of
        SConversationJoinTag ->
          mapToGalleyError @(HasConversationActionGalleyErrors 'ConversationJoinTag) $
            updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationLeaveTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationLeaveTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationRemoveMembersTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationRemoveMembersTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationMemberUpdateTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationMemberUpdateTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationDeleteTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationDeleteTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationRenameTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationRenameTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationMessageTimerUpdateTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationMessageTimerUpdateTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationReceiptModeUpdateTag ->
          mapToGalleyError @(HasConversationActionGalleyErrors 'ConversationReceiptModeUpdateTag) $
            updateLocalConversationWithRemoteUser tag lcnv rusr action
        SConversationAccessDataTag ->
          mapToGalleyError
            @(HasConversationActionGalleyErrors 'ConversationAccessDataTag)
            $ updateLocalConversationWithRemoteUser tag lcnv rusr action
  where
    mkResponse = fmap toResponse . runError @GalleyError . runError @NoChanges

    toResponse (Left galleyErr) = F.ConversationUpdateResponseError galleyErr
    toResponse (Right (Left NoChanges)) = F.ConversationUpdateResponseNoChanges
    toResponse (Right (Right update)) = F.ConversationUpdateResponseUpdate update

class ToGalleyRuntimeError (effs :: EffectRow) r where
  mapToGalleyError ::
    Member (Error GalleyError) r =>
    Sem (Append effs r) a ->
    Sem r a

instance ToGalleyRuntimeError '[] r where
  mapToGalleyError = id

instance
  forall (err :: GalleyError) effs r.
  ( ToGalleyRuntimeError effs r,
    SingI err,
    Member (Error GalleyError) (Append effs r)
  ) =>
  ToGalleyRuntimeError (ErrorS err ': effs) r
  where
  mapToGalleyError act =
    mapToGalleyError @effs @r $
      runError act >>= \case
        Left _ -> throw (demote @err)
        Right res -> pure res

mlsSendWelcome ::
  Members
    '[ GundeckAccess,
       Input (Local ()),
       Input UTCTime
     ]
    r =>
  Domain ->
  F.MLSWelcomeRequest ->
  Sem r ()
mlsSendWelcome _origDomain (F.MLSWelcomeRequest b64RawWelcome rcpts) = do
  loc <- input @(Local ())
  now <- input @UTCTime
  let rawWelcome = fromBase64ByteString b64RawWelcome
  void $
    runMessagePush loc Nothing $
      foldMap (uncurry $ mkPush rawWelcome loc now) (F.unMLSWelRecipient <$> rcpts)
  where
    mkPush :: ByteString -> Local x -> UTCTime -> UserId -> ClientId -> MessagePush 'Broadcast
    mkPush rawWelcome l time u c =
      -- FUTUREWORK: use the conversation ID stored in the key package mapping table
      let lcnv = qualifyAs l (Data.selfConv u)
          lusr = qualifyAs l u
          e = Event (qUntagged lcnv) (qUntagged lusr) time $ EdMLSWelcome rawWelcome
       in newMessagePush l () Nothing defMessageMetadata (u, c) e
