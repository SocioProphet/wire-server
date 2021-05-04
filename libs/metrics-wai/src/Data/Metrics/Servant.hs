{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

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

-- | Given a servant API type, this module gives you a 'Paths' for 'withPathTemplate'.
module Data.Metrics.Servant where

import Data.Metrics.Middleware.Prometheus (normalizeWaiRequestRoute)
import Data.Metrics.Types
import qualified Data.Metrics.Types as Metrics
import Data.Metrics.WaiRoute (treeToPaths)
import Data.Proxy
import Data.String.Conversions
import Data.Tree
import GHC.TypeLits
import Imports
import qualified Network.Wai as Wai
import Network.Wai.Middleware.Prometheus
import qualified Network.Wai.Middleware.Prometheus as Promth
import Network.Wai.Routing (Routes, prepare)
import Servant.API

-- | This does not catch errors, so it must be called outside of 'WU.catchErrors'.
servantPrometheusMiddleware :: forall proxy api. (RoutesToPaths api) => proxy api -> Wai.Middleware
servantPrometheusMiddleware _ = Promth.prometheus conf . Promth.instrumentHandlerValue promthNormalize
  where
    promthNormalize :: Wai.Request -> Text
    promthNormalize req = pathInfo
      where
        mPathInfo = Metrics.treeLookup (routesToPaths @api) $ cs <$> Wai.pathInfo req
        pathInfo = cs $ fromMaybe "N/A" mPathInfo

servantPlusWAIPrometheusMiddleware :: forall proxy api a m b. (RoutesToPaths api, Monad m) => Routes a m b -> proxy api -> Wai.Middleware
servantPlusWAIPrometheusMiddleware routes _ = do
  Promth.prometheus conf . instrument (normalizeWaiRequestRoute paths)
  where
    -- See Note [Raw Response]
    instrument = Promth.instrumentHandlerValueWithFilter Promth.ignoreRawResponses

    paths =
      let Paths servantPaths = routesToPaths @api
          Paths waiPaths = treeToPaths (prepare routes)
       in Paths (meltTree (servantPaths <> waiPaths))

conf :: PrometheusSettings
conf =
  Promth.def
    { Promth.prometheusEndPoint = ["i", "metrics"],
      -- We provide our own instrumentation so we can normalize routes
      Promth.prometheusInstrumentApp = False
    }

routesToPaths :: forall routes. RoutesToPaths routes => Paths
routesToPaths = Paths (meltTree (getRoutes @routes))

class RoutesToPaths routes where
  getRoutes :: Forest PathSegment

-- "seg" :> routes
instance
  {-# OVERLAPPING #-}
  ( KnownSymbol seg,
    RoutesToPaths segs
  ) =>
  RoutesToPaths (seg :> segs)
  where
  getRoutes = [Node (Right . cs $ symbolVal (Proxy @seg)) (getRoutes @segs)]

-- <capture> :> routes
instance
  {-# OVERLAPPING #-}
  ( KnownSymbol capture,
    RoutesToPaths segs
  ) =>
  RoutesToPaths (Capture' mods capture a :> segs)
  where
  getRoutes = [Node (Left (cs (":" <> symbolVal (Proxy @capture)))) (getRoutes @segs)]

-- route :> routes
instance
  {-# OVERLAPPING #-}
  ( RoutesToPaths route,
    RoutesToPaths routes
  ) =>
  RoutesToPaths (route :<|> routes)
  where
  getRoutes = getRoutes @route <> getRoutes @routes

-- stuff to ignore
instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'HEAD status ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'GET status ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'POST status ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'PUT status ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'DELETE status ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (Verb 'PATCH status ctypes content) where
  getRoutes = []

instance RoutesToPaths (NoContentVerb 'DELETE) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'HEAD ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'GET ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'POST ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'PUT ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'DELETE ctypes content) where
  getRoutes = []

instance {-# OVERLAPPING #-} RoutesToPaths (UVerb 'PATCH ctypes content) where
  getRoutes = []

instance RoutesToPaths Raw where
  getRoutes = []

instance
  {-# OVERLAPPING #-}
  ( RoutesToPaths segs
  ) =>
  RoutesToPaths (ReqBody ctypes content :> segs)
  where
  getRoutes = getRoutes @segs

instance
  {-# OVERLAPPING #-}
  ( KnownSymbol sym,
    RoutesToPaths segs
  ) =>
  RoutesToPaths (Header sym content :> segs)
  where
  getRoutes = getRoutes @segs

instance
  {-# OVERLAPPING #-}
  ( KnownSymbol sym,
    RoutesToPaths segs
  ) =>
  RoutesToPaths (QueryParam sym content :> segs)
  where
  getRoutes = getRoutes @segs

instance
  {-# OVERLAPPABLE #-}
  ( RoutesToPaths segs
  ) =>
  RoutesToPaths (anything :> segs)
  where
  getRoutes = getRoutes @segs
