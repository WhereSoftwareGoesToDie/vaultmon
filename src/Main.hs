{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Main where
import qualified System.ZMQ4.Monadic as ZMQ
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as L
import qualified Network.WebSockets as WS
import Control.Applicative((<$>))
import Control.Monad(forever, forM_)
import Control.Concurrent(Chan, writeChan, readChan, newChan, dupChan, threadDelay)
import Control.Concurrent.MVar(swapMVar, takeMVar, putMVar, newMVar)
import Control.Concurrent.Async(link, async)
import Data.Aeson

type YStream = Chan L.ByteString

data Sources = Sources {
    chateau :: YStream
}

data ChateauStats = ChateauStats { burstsPerSecond    :: Int
                                 , bytesPerSecond     :: Int }

instance ToJSON ChateauStats where
    toJSON ChateauStats{..} =
      let mbit   = 131072 :: Double
          mbitps = (fromIntegral bytesPerSecond) / mbit in
        object [ "DataBursts per second" .= burstsPerSecond
               , "Megabits per second"   .= mbitps ]

linkThread :: IO a -> IO ()
linkThread = (link =<<) . async

main :: IO ()
main = do
    sources <- Sources <$> newChan

    linkThread $
        gatherChateau (chateau sources)

    -- Keep the channels drained so we don't leak memory.
    forM_ [chateau] $ \f ->
        linkThread $ forever $ readChan (f sources)

    WS.runServer "0.0.0.0" 8080 $ incomingRequest sources


incomingRequest :: Sources -> WS.PendingConnection -> IO ()
incomingRequest sources request
    | WS.RequestHead "/chateau" _ _ <- (WS.pendingRequest request) =
        WS.acceptRequest request >>= sendYStream (chateau sources)
    | otherwise =
        WS.rejectRequest request "Unknown endpoint"

sendYStream :: YStream -> WS.Connection -> IO ()
sendYStream stream connection = do
    mine <- dupChan stream
    forever $ readChan mine >>= WS.sendTextData connection

waitTick :: IO ()
waitTick = threadDelay 1000000

gatherChateau :: YStream -> IO ()
gatherChateau stream = do
    packets <- newMVar []
    linkThread $ runSnoop packets
    forever $ do
        ps <- swapMVar packets []
        let lengths = map B.length ps

        let stats = ChateauStats { burstsPerSecond = length ps
                                 , bytesPerSecond = sum lengths }

        writeChan stream $ encode stats
        waitTick
  where
    runSnoop packets = do
        ZMQ.runZMQ $ do
            snoop <- ZMQ.socket ZMQ.Sub
            ZMQ.connect snoop "tcp://localhost:5000"
            ZMQ.subscribe snoop ""

            forever $ do
                [_, _, payload] <- ZMQ.receiveMulti snoop
                ZMQ.liftIO $ do
                    ps <- takeMVar packets
                    putMVar packets (payload:ps)
