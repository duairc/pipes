{-|

'Pipe's for doing IO with binary data.

-}

module Control.Pipe.Binary.IO
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

import           Control.Monad (forever, unless, when)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Resource (MonadResource (with, release))
import           Control.Monad.Trans.Class (lift)
import           Control.Pipe.Common
import           System.IO
                     ( Handle
                     , IOMode (ReadMode, WriteMode)
                     , SeekMode (AbsoluteSeek)
                     , hClose
                     , hSeek
                     , openBinaryFile
                     )
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.ByteString.Lazy.Internal (defaultChunkSize)


------------------------------------------------------------------------------
-- | Stream the contents of a file as binary data.
produceFile
    :: MonadResource m
    => FilePath
    -> Producer ByteString m ()
produceFile file = produceIOHandle (openBinaryFile file ReadMode)


------------------------------------------------------------------------------
-- | Stream the contents of a 'Handle' as binary data. Note that this function
-- will /not/ automatically close the Handle when processing completes, since
-- it did not acquire the Handle in the first place.
produceHandle
    :: MonadIO m
    => Handle
    -> Producer ByteString m ()
produceHandle h = go
  where
    go = do
        bs <- liftIO (B.hGetSome h defaultChunkSize)
        unless (B.null bs) $ yield bs >> go


------------------------------------------------------------------------------
-- | An alternative to 'produceHandle'. Instead of taking a pre-opened
-- 'Handle', it takes an action that opens a 'Handle' (in read mode), so that
-- it can open it only when needed and close it as soon as possible.
produceIOHandle
    :: MonadResource m
    => IO Handle
    -> Producer ByteString m ()
produceIOHandle open = do
    (key, h) <- lift $ with open hClose
    produceHandle h
    lift $ release key


------------------------------------------------------------------------------
-- | Stream the contents of a file as binary data, starting from a certain
-- offset and only consuming up to a certain number of bytes.
produceFileRange
    :: MonadResource m
    => FilePath
    -> Maybe Int
    -> Maybe Int
    -> Producer ByteString m ()
produceFileRange file = produceIOHandleRange (openBinaryFile file ReadMode)


------------------------------------------------------------------------------
-- | A version of 'produceFileRange' analogous to 'produceHandle'.
produceHandleRange
    :: MonadIO m
    => Handle
    -> Maybe Int
    -> Maybe Int
    -> Producer ByteString m ()
produceHandleRange h s f = do
    maybe (return ()) (liftIO . hSeek h AbsoluteSeek . fromIntegral) s
    maybe (produceHandle h) go f
  where
    go c = when (c > 0) $ do
        bs <- liftIO (B.hGetSome h (min c defaultChunkSize))
        let bl = B.length bs
            c' = c - bl
        when (bl > 0) $ yield bs >> go (c - bl)


------------------------------------------------------------------------------
-- | A version of 'produceFileRange' analogous to 'produceIOHandle'.
produceIOHandleRange
    :: MonadResource m
    => IO Handle
    -> Maybe Int
    -> Maybe Int
    -> Producer ByteString m ()
produceIOHandleRange open s f = do
    (key, h) <- lift $ with open hClose
    produceHandleRange h s f
    lift $ release key


------------------------------------------------------------------------------
-- | Stream all incoming data to the given file.
consumeFile
    :: MonadResource m
    => FilePath
    -> Consumer ByteString m ()
consumeFile file = consumeIOHandle (openBinaryFile file WriteMode)


------------------------------------------------------------------------------
-- | Stream all incoming data to the given 'Handle'. Note that this function
-- will /not/ automatically close the 'Handle' when processing completes.
consumeHandle
    :: MonadIO m
    => Handle
    -> Consumer ByteString m ()
consumeHandle h = forever $ await >>= liftIO . B.hPut h


------------------------------------------------------------------------------
-- | An alternative to 'consumeHande'. Instead of taking a pre-opened
-- 'Handle', it takes an action that opens a 'Handle' (in write mode), so that
-- it can open it only when needed and close it as soon as possible.
consumeIOHandle
    :: MonadResource m
    => IO Handle
    -> Consumer ByteString m ()
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
    -> Pipe ByteString ByteString m r
teeFile file = teeIOHandle (openBinaryFile file WriteMode)


------------------------------------------------------------------------------
-- | A version of 'teeFile' analogous to 'consumeHandle'.
teeHandle
    :: MonadIO m
    => Handle
    -> Pipe ByteString ByteString m r
teeHandle h = forever $ await >>= \bs -> yield bs >> liftIO (B.hPut h bs)


------------------------------------------------------------------------------
-- | A version of 'teeFile' analogous to 'consumeIOHandle'.
teeIOHandle
    :: MonadResource m
    => IO Handle
    -> Pipe ByteString ByteString m r
teeIOHandle open = do
    (key, h) <- lift $ with open hClose
    teeHandle h
    lift $ release key
    idP
