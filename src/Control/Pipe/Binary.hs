{-# LANGUAGE BangPatterns #-}

{-|

Convenience 'Pipe's, analogous to those in "Control.Pipe.List", for 'Pipe's
containing binary data.

-}

module Control.Pipe.Binary
    ( -- * Producers
      produce

      -- ** Infinite streams
    , iterate
    , iterateM
    , repeat
    , repeatM

      -- ** Bounded streams
    , replicate
    , replicateM
    , unfold
    , unfoldM

      -- * Consumers
    , consume
    , consume'
    , fold
    , foldM
    , mapM_

      -- * Pipes
      -- ** Maps
    , map
    , mapM
    , concatMap
    , concatMapM

      -- ** Accumulating maps
    , mapAccum
    , mapAccumM
    , concatMapAccum
    , concatMapAccumM

      -- ** Dropping input
    , filter
    , filterM
    , drop
    , dropWhile
    , take
    , takeWhile
    , takeUntilByte

      -- ** Other
    , lines
    , words
    )
where

import           Control.Monad (Monad (..), forever, liftM, when)
import           Control.Monad.Trans (lift)
import           Control.Pipe.Common
import qualified Control.Pipe.List as PL
import           Data.Bool (Bool)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import           Data.Function ((.), ($))
import           Data.Functor (fmap)
import           Data.Maybe (Maybe (..))
import           Data.Word (Word8)
import           Prelude (Int, (+), (-), Ord (..), fromIntegral, otherwise)


------------------------------------------------------------------------------
-- | Produces a stream of byte chunks given a lazy 'L.ByteString'.
produce :: Monad m => L.ByteString -> Producer ByteString m ()
produce = PL.produce . L.toChunks


------------------------------------------------------------------------------
-- | @'iterate' f x@ produces an infinite stream of repeated applications of
-- @f@ to @x@.
iterate :: Monad m => (Word8 -> Word8) -> Word8 -> Producer ByteString m b
iterate f a = produce (L.iterate f a) >> discard


------------------------------------------------------------------------------
-- | Similar to 'iterate', except the iteration function is monadic.
iterateM :: Monad m => (Word8 -> m Word8) -> Word8 -> Producer ByteString m b
iterateM f a = PL.iterateM f a >+> pipe B.singleton


------------------------------------------------------------------------------
-- | Produces an infinite stream of a single byte.
repeat :: Monad m => Word8 -> Producer ByteString m b
repeat a = produce (L.repeat a) >> discard


------------------------------------------------------------------------------
-- | Produces an infinite stream of values. Each value is computed by the
-- underlying monad.
repeatM :: Monad m => m Word8 -> Producer ByteString m b
repeatM m = forever $ lift m >>= yield . B.singleton 


------------------------------------------------------------------------------
-- | @'replicate' n x@ produces a stream containing @n@ copies of @x@.
replicate :: Monad m => Int -> Word8 -> Producer ByteString m ()
replicate n = produce . L.replicate (fromIntegral n)


------------------------------------------------------------------------------
-- | @'replicateM' n x@ produces a stream containing @n@ bytes, where each
-- byte is computed by the underlying monad.
replicateM :: Monad m => Int -> m Word8 -> Producer ByteString m ()
replicateM n m = PL.replicateM n m >+> pipe B.singleton


------------------------------------------------------------------------------
-- | Produces a stream of bytes by repeatedly applying a function to some
-- state, until 'Nothing' is returned.
unfold :: Monad m => (c -> Maybe (Word8, c)) -> c -> Producer ByteString m ()
unfold f = produce . L.unfoldr f


------------------------------------------------------------------------------
-- | Produces a stream of bytes by repeatedly applying a computation to some
-- state, until 'Nothing' is returned.
unfoldM
    :: Monad m
    => (c -> m (Maybe (Word8, c)))
    -> c
    -> Producer ByteString m ()
unfoldM f c = PL.unfoldM f c >+> pipe B.singleton


------------------------------------------------------------------------------
-- | Consumes all input chunks and returns a lazy 'L.ByteString'.
consume :: Monad m => Consumer ByteString m L.ByteString
consume = L.fromChunks `liftM` PL.consume


------------------------------------------------------------------------------
-- | Consumes all input chunks and concatenate them into a strict
-- 'ByteString'.
consume' :: Monad m => Consumer ByteString m ByteString
consume' = B.concat `liftM` PL.consume


------------------------------------------------------------------------------
-- | Consume the entire input stream with a strict left monadic fold, one byte
-- at a time.
fold :: Monad m => (b -> Word8 -> b) -> b -> Consumer ByteString m b
fold = PL.fold . B.foldl


------------------------------------------------------------------------------
-- | Consume the entire input stream with a strict left fold, one byte at a
-- time.
foldM :: Monad m => (b -> Word8 -> m b) -> b -> Consumer ByteString m b
foldM f = PL.foldM $ \b -> B.foldl (\mb w -> mb >>= \b -> f b w) (return b)


------------------------------------------------------------------------------
-- | For every byte in a stream, run a computation and discard its result.
mapM_ :: Monad m => (Word8 -> m b) -> Consumer ByteString m r
mapM_ f = foldM (\() a -> f a >> return ()) () >> discard


------------------------------------------------------------------------------
-- | 'map' transforms a byte stream by applying a transformation to each byte
-- in the stream.
map :: Monad m => (Word8 -> Word8) -> Pipe ByteString ByteString m r
map = pipe . B.map


------------------------------------------------------------------------------
-- | 'map' transforms a byte stream by applying a monadic transformation to
-- each byte in the stream.
mapM :: Monad m => (Word8 -> m Word8) -> Pipe ByteString ByteString m r
mapM f = concatMapM (liftM B.singleton . f)


------------------------------------------------------------------------------
-- | 'concatMap' transforms a byte stream by applying a transformation to each
-- byte in the stream and concatenating the results.
concatMap
    :: Monad m
    => (Word8 -> ByteString)
    -> Pipe ByteString ByteString m r
concatMap = pipe . B.concatMap


------------------------------------------------------------------------------
-- | 'concatMapM' transforms a byte stream by applying a monadic
-- transformation to each byte in the stream and concatenating the results.
concatMapM
    :: Monad m
    => (Word8 -> m ByteString)
    -> Pipe ByteString ByteString m r
concatMapM f = forever $ do
    await >>= B.foldl (\m w -> m >> lift (f w) >>= yield) (return ())


------------------------------------------------------------------------------
-- | Similar to 'map', but with a stateful step function.
mapAccum
    :: Monad m
    => (c -> Word8 -> (c, Word8))
    -> c
    -> Pipe ByteString ByteString m r
mapAccum f = go
  where
    go !c = do
        bs <- await
        let (c', bs') = B.mapAccumL f c bs
        yield bs'
        go c'


------------------------------------------------------------------------------
-- | Similar to 'mapM', but with a stateful step function.
mapAccumM
    :: Monad m
    => (c -> Word8 -> m (c, Word8))
    -> c
    -> Pipe ByteString ByteString m r
mapAccumM f = concatMapAccumM (\c w -> liftM (fmap B.singleton) (f c w))


------------------------------------------------------------------------------
-- | Similar to 'concatMap', but with a stateful step function.
concatMapAccum
    :: Monad m
    => (c -> Word8 -> (c, ByteString))
    -> c
    -> Pipe ByteString ByteString m r
concatMapAccum f = concatMapAccumM (\c w -> return (f c w))


------------------------------------------------------------------------------
-- | Similar to 'concatMapM', but with a stateful step function.
concatMapAccumM
    :: Monad m
    => (c -> Word8 -> m (c, ByteString))
    -> c
    -> Pipe ByteString ByteString m r
concatMapAccumM f = go
  where
    go c = await >>= B.foldl (\mc w -> do
        c <- mc
        (c', bs) <- lift (f c w)
        yield bs
        return c') (return c) >>= go


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the bytes in the stream which match the predicate
-- @p@.
filter :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m r
filter = pipe . B.filter


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the bytes in the stream which match the monadic
-- predicate @p@.
filterM :: Monad m => (Word8 -> m Bool) -> Pipe ByteString ByteString m r
filterM f = go
  where
    go = await >>= B.foldl (\m w -> do
        m
        bool <- lift (f w)
        when bool $ yield $ B.singleton w) (return ()) >> go


------------------------------------------------------------------------------
-- | @'drop' n@ discards the first @n@ bytes from the stream.
drop :: Monad m => Int -> Pipe ByteString ByteString m ()
drop n = do
    bs <- await
    let n' = n - B.length bs
    if n' > 0 then drop n' else do unuse $ B.drop n bs


------------------------------------------------------------------------------
-- | @'dropWhile' p@ discards bytes from the stream until they no longer match
-- the predicate @p@.
dropWhile :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m ()
dropWhile p = go
  where
    go = do
        bs <- await
        let (bad, good) = B.span p bs
        if B.null good then go else unuse good


------------------------------------------------------------------------------
-- | @'take' n@ allows the first @n@ bytes to pass through the stream, and
-- then terminates.
take :: Monad m => Int -> Pipe ByteString ByteString m ()
take n = do
    bs <- await
    let n' = n - B.length bs
    if n' > 0 then yield bs >> take n' else do
        let (good, bad) = B.splitAt n bs
        unuse bad
        yield good


------------------------------------------------------------------------------
-- | @'takeWhile' p@ allows bytes to pass through the stream as long as they
-- match the predicate @p@, and terminates after the first byte that does not
-- match @p@.
takeWhile :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m ()
takeWhile p = go
  where
    go = do
        bs <- await
        let (good, bad) = B.span p bs
        yield good
        if B.null bad then go else unuse bad


------------------------------------------------------------------------------
-- | @'takeUntilByte' c@ allows bytes to pass through the stream until the
-- byte @w@ is found in the stream. This is equivalent to 'takeWhile'
-- @(not . (==c))@, but is more efficient.
takeUntilByte :: Monad m => Word8 -> Pipe ByteString ByteString m ()
takeUntilByte w = go
  where
    go = do
        bs <- await
        let (good, bad) = B.breakByte w bs
        yield good
        if B.null bad then go else unuse bad


------------------------------------------------------------------------------
-- | Split the input bytes into lines. This makes each input chunk correspend
-- to exactly one line, even if that line was originally spread across several
-- chunks.
lines :: Monad m => Pipe ByteString ByteString m r
lines = forever $ do
    ((takeUntilByte 10 >> return B.empty) >+> consume') >>= yield
    drop 1


------------------------------------------------------------------------------
-- | Split the input bytes into words. This makes each input chunk correspend
-- to exactly one word, even if that word was originally spread across several
-- chunks.
words :: Monad m => Pipe ByteString ByteString m r
words = forever $ do
    ((takeUntilByte 32 >> return B.empty) >+> consume') >>= yield
    drop 1
