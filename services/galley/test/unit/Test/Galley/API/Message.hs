-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2021 Wire Swiss GmbH <opensource@wire.com>
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

module Test.Galley.API.Message where

import Data.Domain (Domain)
import Data.Id (ClientId, UserId)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Galley.API.Message
import Imports
import Test.Tasty
import Test.Tasty.QuickCheck
import Wire.API.Message
import Wire.API.User.Client (QualifiedUserClients (..))

tests :: TestTree
tests =
  testGroup
    "Galley.API.Message"
    [ testGroup
        "checkMessageClients"
        [ checkMessageClientSuccess,
          checkMessageClientEverythingReported,
          checkMessageClientRedundantSender,
          checkMessageClientMissingSubsetOfStrategy
        ]
    ]

type QualifiedUserClient = (Domain, UserId, ClientId)

recipientSetToMap :: Set QualifiedUserClient -> Map (Domain, UserId) (Set ClientId)
recipientSetToMap = Set.foldr (\(d, u, c) m -> Map.insertWith Set.union (d, u) (Set.singleton c) m) mempty

checkMessageClientSuccess :: TestTree
checkMessageClientSuccess = testProperty "success" $
  \(sender :: QualifiedUserClient) (msg :: Map QualifiedUserClient ByteString) (strat :: ClientMismatchStrategy) ->
    let expectedRecipients = Map.keysSet msg
        expectedRecipientMap = recipientSetToMap expectedRecipients
     in not (Map.member sender msg)
          ==> checkMessageClients sender expectedRecipientMap msg strat
          === (True, msg, QualifiedMismatch mempty mempty mempty)

checkMessageClientRedundantSender :: TestTree
checkMessageClientRedundantSender = testProperty "sender should be part of redundant" $
  \(msg0 :: Map QualifiedUserClient ByteString) (sender :: QualifiedUserClient) (strat :: ClientMismatchStrategy) ->
    let msg = Map.insert sender "msg to self" msg0
        expectedRecipients = Map.keysSet msg0
        expectedRecipientMap = recipientSetToMap expectedRecipients
     in checkMessageClients sender expectedRecipientMap msg strat
          === (True, msg0, QualifiedMismatch mempty (mkQualifiedUserClients (Set.singleton sender)) mempty)

-- | FUTUREWORK: Write a custom generator for this test. expected' and
-- expected'' are used along with msg to generate expected, this ensures that we
-- don't always get a disjoint set between the intended recipietns and expected
-- recipients.
checkMessageClientEverythingReported :: TestTree
checkMessageClientEverythingReported = testProperty "all intended and expected recipients should be part of valid and extras" $
  \(sender :: QualifiedUserClient) (expected' :: Set QualifiedUserClient) (msg0 :: Map QualifiedUserClient ByteString) (msg' :: Map QualifiedUserClient ByteString) ->
    let expectedRecipients = Map.keysSet msg0 <> expected'
        expectedRecipientMap = recipientSetToMap expectedRecipients
        msg = msg0 <> msg'
        intendedRecipients = Map.keysSet msg
        (_, validMessages, mismatch) = checkMessageClients sender expectedRecipientMap msg MismatchReportAll
        validRecipients = Map.keysSet validMessages
        extraRecipients = flatten . qualifiedUserClients $ qmMissing mismatch <> qmDeleted mismatch <> qmRedundant mismatch
     in validRecipients <> extraRecipients
          === intendedRecipients <> expectedRecipients

checkMessageClientMissingSubsetOfStrategy :: TestTree
checkMessageClientMissingSubsetOfStrategy = testProperty "missing clients should be a subset of the clients determined by the strategy" $
  \(sender :: QualifiedUserClient) (expected' :: Set QualifiedUserClient) (msg0 :: Map QualifiedUserClient ByteString) (msg' :: Map QualifiedUserClient ByteString) (strat :: ClientMismatchStrategy) ->
    let expected = Map.keysSet msg0 <> expected'
        expectedMap = recipientSetToMap expected
        msg = msg0 <> msg'
        stratClients = clientMismatchStrategyApply strat expected
        (_, _, mismatch) = checkMessageClients sender expectedMap msg strat
        missing = flatten . qualifiedUserClients $ qmMissing mismatch
     in Set.isSubsetOf missing stratClients
