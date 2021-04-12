{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2020 Wire Swiss GmbH <opensource@wire.com>
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

module Brig.Federation.Client where

import Brig.API.Error (throwStd)
import Brig.API.Handler (Handler)
import Brig.API.Types (FedError (..))
import Brig.App (AppIO, federator)
import Brig.Types.User
import Control.Error.Util ((!?))
import Control.Lens (view, (^.))
import Control.Monad.Trans.Except (ExceptT (..), throwE)
import qualified Data.Aeson as Aeson
import Data.Domain (Domain)
import Data.Handle
import Data.Id (ClientId, UserId)
import qualified Data.Map as Map
import Data.Qualified
import Data.String.Conversions
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Imports
import Mu.GRpc.Client.TyApps
import qualified Network.HTTP.Types.Status as HTTP
import qualified Network.Wai.Utilities.Error as Wai
import qualified System.Logger.Class as Log
import Util.Options (epHost, epPort)
import Wire.API.Federation.API.Brig
import Wire.API.Federation.GRPC.Client
import qualified Wire.API.Federation.GRPC.Types as Proto
import Wire.API.User.Client.Prekey (ClientPrekey)

type FedAppIO = ExceptT FedError AppIO

-- FUTUREWORK(federation): As of now, any failure in making a remote call results in 404.
-- This is not correct, we should figure out how we communicate failure
-- scenarios to the clients.
-- See https://wearezeta.atlassian.net/browse/SQCORE-491 for the issue on error handling improvements.
getUserHandleInfo :: Qualified Handle -> FedAppIO (Maybe UserProfile)
getUserHandleInfo (Qualified handle domain) = do
  Log.info $ Log.msg ("Brig-federation: handle lookup call on remote backend" :: ByteString)
  federatorClient <- mkFederatorClient
  let call = Proto.ValidatedFederatedRequest domain (mkGetUserInfoByHandle handle)
  res <- expectOk =<< callRemote federatorClient call
  case Proto.responseStatus res of
    404 -> pure Nothing
    200 -> case Aeson.eitherDecodeStrict (Proto.responseBody res) of
      Left err -> throwE (InvalidResponseBody (T.pack err))
      Right x -> pure $ Just x
    code -> throwE (InvalidResponseCode code)

-- FUTUREWORK(federation): Abstract out all the rpc boilerplate and error handling
claimPrekey :: Qualified UserId -> ClientId -> FedAppIO (Maybe ClientPrekey)
claimPrekey (Qualified user domain) client = do
  Log.info $ Log.msg @Text "Brig-federation: claiming remote prekey"
  federatorClient <- mkFederatorClient
  let call = Proto.ValidatedFederatedRequest domain (mkClaimPrekey user client)
  res <- expectOk =<< callRemote federatorClient call
  case Proto.responseStatus res of
    404 -> pure Nothing
    200 -> case Aeson.eitherDecodeStrict (Proto.responseBody res) of
      Left err -> throwE (InvalidResponseBody (T.pack err))
      Right x -> pure $ Just x
    code -> throwE (InvalidResponseCode code)

-- FUTUREWORK: Test
getUsersByIds :: [Qualified UserId] -> FedAppIO [UserProfile]
getUsersByIds quids = do
  Log.info $ Log.msg ("Brig-federation: get users by ids on remote backends" :: ByteString)
  federatorClient <- mkFederatorClient
  let domainWiseIds = qualifiedToMap quids
      requests = Map.foldMapWithKey (\domain uids -> [Proto.ValidatedFederatedRequest domain (mkGetUsersByIds uids)]) domainWiseIds
  -- TODO: Make these concurrent
  concat <$> mapM (processResponse <=< expectOk <=< callRemote federatorClient) requests
  where
    -- TODO: Do we want to not fail the whole request if there is one bad remote?
    processResponse :: Proto.HTTPResponse -> FedAppIO [UserProfile]
    processResponse res =
      case Proto.responseStatus res of
        200 -> case Aeson.eitherDecodeStrict (Proto.responseBody res) of
          Left err -> throwE (InvalidResponseBody (T.pack err))
          Right profiles -> pure profiles
        code -> throwE (InvalidResponseCode code)

qualifiedToMap :: [Qualified a] -> Map Domain [a]
qualifiedToMap = Map.fromListWith (<>) . map (\(Qualified thing domain) -> (domain, [thing]))

-- FUTUREWORK: It would be nice to share the client across all calls to
-- federator and not call this function on every invocation of federated
-- requests, but there are some issues in http2-client which might need some
-- fixing first. More context here:
-- https://github.com/lucasdicioccio/http2-client/issues/37
-- https://github.com/lucasdicioccio/http2-client/issues/49
mkFederatorClient :: FedAppIO GrpcClient
mkFederatorClient = do
  federatorEndpoint <- view federator !? FederationNotConfigured
  let cfg = grpcClientConfigSimple (T.unpack (federatorEndpoint ^. epHost)) (fromIntegral (federatorEndpoint ^. epPort)) False
  -- TODO: add error message to FederationUnavailable
  createGrpcClient cfg
    >>= either (throwE . const FederationUnavailable) pure

callRemote :: MonadIO m => GrpcClient -> Proto.ValidatedFederatedRequest -> m (GRpcReply Proto.OutwardResponse)
callRemote fedClient call = liftIO $ gRpcCall @'MsgProtoBuf @Proto.Outward @"Outward" @"call" fedClient (Proto.validatedFederatedRequestToFederatedRequest call)

-- FUTUREWORK(federation) All of this code is only exercised in the test which
-- goes between two Backends. This is not ideal, we should figure out a way to
-- test client side of federated code without needing another backend. We could
-- do this either by mocking the second backend in integration tests or making
-- all of this independent of the Handler monad and write unit tests.
expectOk :: GRpcReply Proto.OutwardResponse -> FedAppIO Proto.HTTPResponse
expectOk = \case
  GRpcTooMuchConcurrency _tmc -> rpcErr "too much concurrency"
  GRpcErrorCode code -> rpcErr $ "grpc error code: " <> T.pack (show code)
  GRpcErrorString msg -> rpcErr $ "grpc error: " <> T.pack msg
  GRpcClientError msg -> rpcErr $ "grpc client error: " <> T.pack (show msg)
  GRpcOk (Proto.OutwardResponseError err) ->
    let (label, msg) = decodeError (Proto.outwardErrorPayload err)
        status = case Proto.outwardErrorType err of
          Proto.RemoteNotFound -> HTTP.status422
          Proto.DiscoveryFailed -> HTTP.status500
          Proto.ConnectionRefused -> HTTP.Status 521 "Web Server Is Down"
          Proto.TLSFailure -> HTTP.Status 525 "SSL Handshake Failure"
          Proto.InvalidCertificate -> HTTP.Status 526 "Invalid SSL Certificate"
          Proto.VersionMismatch -> HTTP.Status 531 "Version Mismatch"
          Proto.FederationDeniedByRemote -> HTTP.Status 532 "Federation Denied"
          Proto.FederationDeniedLocally -> HTTP.status400
          Proto.RemoteFederatorError -> HTTP.Status 533 "Unexpected Federation Response"
          Proto.InvalidRequest -> HTTP.status500
     in throwE (FederationRemoteError status label msg)
  GRpcOk (Proto.OutwardResponseHTTPResponse res) -> pure res
  where
    rpcErr :: Text -> FedAppIO a
    rpcErr msg = throwE (FedRpcError msg)

    decodeError :: Maybe Proto.ErrorPayload -> (Text, Text)
    decodeError Nothing = ("unknown-federation-error", "Unknown federation error")
    decodeError (Just (Proto.ErrorPayload label msg)) = (label, msg)

errWithPayloadAndStatus :: Maybe Proto.ErrorPayload -> HTTP.Status -> Wai.Error
errWithPayloadAndStatus maybePayload code =
  case maybePayload of
    Nothing -> Wai.Error code "unknown-federation-error" "no payload present"
    Just Proto.ErrorPayload {..} -> Wai.Error code (LT.fromStrict label) (LT.fromStrict msg)

grpc500 :: LT.Text -> Handler a
grpc500 msg = do
  throwStd $ Wai.Error HTTP.status500 "federator-grpc-failure" msg

throwJsonParseFailure :: String -> Handler a
throwJsonParseFailure err =
  throwStd $ Wai.Error statusUnexpectedFederationResponse "invalid-json-from-remote" ("Failed to parse json with error: " <> LT.pack err)

throwUnknownStatusError :: Word32 -> Handler a
throwUnknownStatusError status =
  throwStd $ Wai.Error statusUnexpectedFederationResponse "unknown-status-from-remote" ("Unknown status from remote: " <> LT.pack (show status))

statusUnexpectedFederationResponse :: HTTP.Status
statusUnexpectedFederationResponse = HTTP.Status 533 "Unexpected Federation Response"
