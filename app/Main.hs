--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude

import Control.Concurrent.Async
    ( ExceptionInLinkedThread (..) )
import Control.Exception
    ( catch, fromException, handle, throwIO )
import Control.Monad
    ( unless )
import Control.Tracer
    ( Tracer, contramap, traceWith )
import Data.Function
    ( (&) )
import Data.String
    ( IsString (..) )
import Network.HTTP.Types.Header
    ( hUserAgent )
import Network.WebSockets
    ( ConnectionException (..) )
import System.Directory
    ( doesPathExist )

import Cardano.BM.Trace.Extra
    ( withStdoutTracer )
import Cardano.Byron.Constants
    ( EpochSlots, NodeVersionData, lookupVersionData )
import Cardano.Byron.Network.Protocol.NodeToClient
    ( connectClient, mkClient )
import Cardano.Byron.Types.Json.Orphans
    ()

import Ogmios.Bridge
    ( handleIOException, pipeClients, serviceDescription )
import Ogmios.Options.Applicative
    ( Options (..), parseOptions )
import Ogmios.Trace
    ( TraceOgmios (..) )

import qualified Data.List as L
import qualified Data.Text as T
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WebSockets as Wai
import qualified Network.WebSockets as WS

main :: IO ()
main = do
    opts@Options{logLevel} <- parseOptions
    withStdoutTracer "ogmios" logLevel (T.pack . show) $ runServer opts
  where
    runServer opts@Options{host,port,publicUrl,nodeSocket} tr = do
        env <- lookupVersionData (contramap OgmiosLookupEnv tr) "OGMIOS_NETWORK"
        Warp.runSettings settings $ Wai.websocketsOr WS.defaultConnectionOptions
            (websocketApp tr env opts)
            (serviceDescription publicUrl)
      where
        settings = Warp.defaultSettings
            & Warp.setHost (fromString host)
            & Warp.setPort port
            & Warp.setBeforeMainLoop (do
                socketExist <- doesPathExist nodeSocket
                unless socketExist $ traceWith tr $ OgmiosSocketNotFound nodeSocket
                traceWith tr OgmiosStarted{host,port}
            )

-- | The actual WebSocket server, creating a new connection to cardano-node
-- for each WebSocket client connected.
websocketApp
    :: Tracer IO TraceOgmios
    -> (NodeVersionData, EpochSlots)
    -> Options
    -> WS.ServerApp
websocketApp tr (nodeVersionData, epochSlots) Options{nodeSocket} pending = do
    traceWith tr (OgmiosConnectionAccepted userAgent)
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (pure ()) $ handlers $ do
        let trClient = contramap OgmiosClient tr
        (chainSync, txSubmit, stateQuery) <- pipeClients conn
        let client = mkClient trClient epochSlots chainSync txSubmit stateQuery
        connectClient trClient client nodeVersionData nodeSocket
            `catch` handleIOException tr conn
        traceWith tr $ OgmiosConnectionEnded userAgent
  where
    userAgent = maybe "User-Agent unknown" snd
        $ L.find ((== hUserAgent) . fst)
        $ WS.requestHeaders
        $ WS.pendingRequest pending

    handlers
        = handle onUnknownException
        . handle onConnectionClosed
        . handle onLinkedException

    onConnectionClosed = \case
        CloseRequest{} -> traceWith tr $ OgmiosConnectionEnded userAgent
        ConnectionClosed{} -> traceWith tr $ OgmiosConnectionEnded userAgent
        e -> throwIO e

    onLinkedException = \case
        ExceptionInLinkedThread _ e -> case fromException e of
            Just e' -> onConnectionClosed e'
            Nothing -> throwIO e

    onUnknownException = traceWith tr . OgmiosUnknownException