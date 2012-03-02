{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

{-|

'Pipe's for doing IO with text data.

-}

module Control.Pipe.Text.IO
    ( -- * Producers
      produceFile
    , produceHandle
    , produceIOHandle

      -- ** Ranges
    , produceFileRange
    , produceHandleRange
    , produceIOHandleRange

      -- * Consumers
    , consumeFile
    , consumeHandle
    , consumeIOHandle

      -- * Pipes
    , teeFile
    , teeHandle
    , teeIOHandle
    )
where

import           Control.Monad (forever)
import           Control.Monad.Exception.Class (MonadException)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Resource (MonadResource (with, release))
import           Control.Monad.Trans (lift)
import qualified Control.Pipe.Binary.IO as PB
import           Control.Pipe.Common
import           Control.Pipe.Text.Encoding
import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text.IO as T
import           System.IO
                     ( Handle
                     , IOMode (ReadMode, WriteMode)
                     , hClose
                     , hGetEncoding
                     , localeEncoding
                     , openFile
                     )


------------------------------------------------------------------------------
-- | Stream the contents of a file as binary data.
produceFile
    :: (MonadResource m, MonadException m)
    => FilePath
    -> Producer Text m ()
produceFile file = produceIOHandle (openFile file ReadMode)


------------------------------------------------------------------------------
-- | Stream the contents of a 'Handle' as text data. Note that this function
-- will /not/ automatically close the Handle when processing completes, since
-- it did not acquire the Handle in the first place.
produceHandle
    :: (MonadIO m, MonadException m)
    => Handle
    -> Producer Text m ()
produceHandle h = do
    encoding <- liftIO $ hGetEncoding h
    PB.produceHandle h >+> decode (fromMaybe localeEncoding encoding)


------------------------------------------------------------------------------
-- | An alternative to 'produceHandle'. Instead of taking a pre-opened
-- 'Handle', it takes an action that opens a 'Handle' (in read mode), so that
-- it can open it only when needed and close it as soon as possible.
produceIOHandle
    :: (MonadResource m, MonadException m)
    => IO Handle
    -> Producer Text m ()
produceIOHandle open = do
    (key, h) <- lift $ with open hClose
    produceHandle h
    lift $ release key


------------------------------------------------------------------------------
-- | Stream the contents of a file as text data, starting from a certain
-- offset and only consuming up to a certain number of bytes.
produceFileRange
    :: (MonadResource m, MonadException m)
    => FilePath
    -> Maybe Int
    -> Maybe Int
    -> Producer Text m ()
produceFileRange file = produceIOHandleRange (openFile file ReadMode)


------------------------------------------------------------------------------
-- | A version of 'produceFileRange' analogous to 'produceHandle'.
produceHandleRange
    :: (MonadIO m, MonadException m)
    => Handle
    -> Maybe Int
    -> Maybe Int
    -> Producer Text m ()
produceHandleRange h s f = do
    encoding <- liftIO $ hGetEncoding h
    PB.produceHandleRange h s f >+> decode (fromMaybe localeEncoding encoding)


------------------------------------------------------------------------------
-- | A version of 'produceFileRange' analogous to 'produceIOHandle'.
produceIOHandleRange
    :: (MonadResource m, MonadException m)
    => IO Handle
    -> Maybe Int
    -> Maybe Int
    -> Producer Text m ()
produceIOHandleRange open s f = do
    (key, h) <- lift $ with open hClose
    produceHandleRange h s f
    lift $ release key


------------------------------------------------------------------------------
-- | Stream all incoming data to the given file.
consumeFile
    :: MonadResource m
    => FilePath
    -> Consumer Text m ()
consumeFile file = consumeIOHandle (openFile file WriteMode)


------------------------------------------------------------------------------
-- | Stream all incoming data to the given 'Handle'. Note that this function
-- will /not/ automatically close the 'Handle' when processing completes.
consumeHandle
    :: MonadIO m
    => Handle
    -> Consumer Text m ()
consumeHandle h = forever $ await >>= liftIO . T.hPutStr h


------------------------------------------------------------------------------
-- | An alternative to 'consumeHande'. Instead of taking a pre-opened
-- 'Handle', it takes an action that opens a 'Handle' (in write mode), so that
-- it can open it only when needed and close it as soon as possible.
consumeIOHandle
    :: MonadResource m
    => IO Handle
    -> Consumer Text m ()
consumeIOHandle open = do
    (key, h) <- lift $ with open hClose
    consumeHandle h
    lift $ release key


------------------------------------------------------------------------------
-- | Stream all incoming data to a file, while also passing it along the
-- pipeline. Similar in concept to the Unix command @tee@.
teeFile
    :: MonadResource m
    => FilePath
    -> Pipe Text Text m r
teeFile file = teeIOHandle (openFile file WriteMode)


------------------------------------------------------------------------------
-- | A version of 'teeFile' analogous to 'consumeHandle'.
teeHandle
    :: MonadIO m
    => Handle
    -> Pipe Text Text m r
teeHandle h = forever $ await >>= \bs -> yield bs >> liftIO (T.hPutStr h bs)


------------------------------------------------------------------------------
-- | A version of 'teeFile' analogous to 'consumeIOHandle'.
teeIOHandle
    :: MonadResource m
    => IO Handle
    -> Pipe Text Text m r
teeIOHandle open = do
    (key, h) <- lift $ with open hClose
    teeHandle h
    lift $ release key
    idP
