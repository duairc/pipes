{-# LANGUAGE BangPatterns #-}

{-|

Convenience 'Pipe's, analogous to those in "Control.Pipe.List", for 'Pipe's
containing text data.

-}

module Control.Pipe.Text
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

      -- ** Other
    , lines
    , words
    )
where

import           Control.Monad (Monad (..), forever, liftM, when)
import           Control.Monad.Trans (lift)
import           Control.Pipe.Common
import qualified Control.Pipe.List as PL
import           Data.Bool (Bool, not)
import           Data.Char (Char)
import           Data.Function ((.), ($))
import           Data.Functor (fmap)
import           Data.Maybe (Maybe (..))
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as L
import           Prelude (Int, (>), (==), (+), (-), fromIntegral, otherwise)


------------------------------------------------------------------------------
-- | Produces a stream of text chunks given a lazy 'L.Text'.
produce :: Monad m => L.Text -> Producer Text m ()
produce = PL.produce . L.toChunks


------------------------------------------------------------------------------
-- | @'iterate' f x@ produces an infinite stream of repeated applications of
-- @f@ to @x@.
iterate :: Monad m => (Char -> Char) -> Char -> Producer Text m b
iterate f = iterateM (return . f)


------------------------------------------------------------------------------
-- | Similar to 'iterate', except the iteration function is monadic.
iterateM :: Monad m => (Char -> m Char) -> Char -> Producer Text m b
iterateM f a = PL.iterateM f a >+> pipe T.singleton


------------------------------------------------------------------------------
-- | Produces an infinite stream of a single character.
repeat :: Monad m => Char -> Producer Text m b
repeat = repeatM . return


------------------------------------------------------------------------------
-- | Produces an infinite stream of values. Each value is computed by the
-- underlying monad.
repeatM :: Monad m => m Char -> Producer Text m b
repeatM m = forever $ lift m >>= yield . T.singleton 


------------------------------------------------------------------------------
-- | @'replicate' n x@ produces a stream containing @n@ copies of @x@.
replicate :: Monad m => Int -> Char -> Producer Text m ()
replicate n = produce . L.replicate (fromIntegral n) . L.singleton


------------------------------------------------------------------------------
-- | @'replicateM' n x@ produces a stream containing @n@ characters, where
-- each character is computed by the underlying monad.
replicateM :: Monad m => Int -> m Char -> Producer Text m ()
replicateM n m = PL.replicateM n m >+> pipe T.singleton


------------------------------------------------------------------------------
-- | Produces a stream of text by repeatedly applying a function to some
-- state, until 'Nothing' is returned.
unfold :: Monad m => (c -> Maybe (Char, c)) -> c -> Producer Text m ()
unfold f = produce . L.unfoldr f


------------------------------------------------------------------------------
-- | Produces a stream of text by repeatedly applying a computation to some
-- state, until 'Nothing' is returned.
unfoldM
    :: Monad m
    => (c -> m (Maybe (Char, c)))
    -> c
    -> Producer Text m ()
unfoldM f c = PL.unfoldM f c >+> pipe T.singleton


------------------------------------------------------------------------------
-- | Consumes all input chunks and returns a lazy 'L.Text'.
consume :: Monad m => Consumer Text m L.Text
consume = L.fromChunks `liftM` PL.consume


------------------------------------------------------------------------------
-- | Consumes all input chunks and concatenate them into a strict
-- 'Text'.
consume' :: Monad m => Consumer Text m Text
consume' = T.concat `liftM` PL.consume


------------------------------------------------------------------------------
-- | Consume the entire input stream with a strict left monadic fold, one
-- character at a time.
fold :: Monad m => (b -> Char -> b) -> b -> Consumer Text m b
fold = PL.fold . T.foldl


------------------------------------------------------------------------------
-- | Consume the entire input stream with a strict left fold, one character at
-- a time.
foldM :: Monad m => (b -> Char -> m b) -> b -> Consumer Text m b
foldM f = PL.foldM $ \b -> T.foldl (\mb w -> mb >>= \b -> f b w) (return b)


------------------------------------------------------------------------------
-- | For every character in a stream, run a computation and discard its
-- result.
mapM_ :: Monad m => (Char -> m b) -> Consumer Text m r
mapM_ f = foldM (\() a -> f a >> return ()) () >> discard


------------------------------------------------------------------------------
-- | 'map' transforms a text stream by applying a transformation to each
-- character in the stream.
map :: Monad m => (Char -> Char) -> Pipe Text Text m r
map = pipe . T.map


------------------------------------------------------------------------------
-- | 'map' transforms a text stream by applying a monadic transformation
-- to each character in the stream.
mapM :: Monad m => (Char -> m Char) -> Pipe Text Text m r
mapM f = concatMapM (liftM T.singleton . f)


------------------------------------------------------------------------------
-- | 'concatMap' transforms a text stream by applying a transformation to each
-- character in the stream and concatenating the results.
concatMap
    :: Monad m
    => (Char -> Text)
    -> Pipe Text Text m r
concatMap = pipe . T.concatMap


------------------------------------------------------------------------------
-- | 'concatMapM' transforms a text stream by applying a monadic
-- transformation to each character in the stream and concatenating the
-- results.
concatMapM
    :: Monad m
    => (Char -> m Text)
    -> Pipe Text Text m r
concatMapM f = forever $ do
    await >>= T.foldl (\m w -> m >> lift (f w) >>= yield) (return ())


------------------------------------------------------------------------------
-- | Similar to 'map', but with a stateful step function.
mapAccum
    :: Monad m
    => (c -> Char -> (c, Char))
    -> c
    -> Pipe Text Text m r
mapAccum f = go
  where
    go !c = do
        text <- await
        let (c', text') = T.mapAccumL f c text
        yield text'
        go c'


------------------------------------------------------------------------------
-- | Similar to 'mapM', but with a stateful step function.
mapAccumM
    :: Monad m
    => (c -> Char -> m (c, Char))
    -> c
    -> Pipe Text Text m r
mapAccumM f = concatMapAccumM (\c w -> liftM (fmap T.singleton) (f c w))


------------------------------------------------------------------------------
-- | Similar to 'concatMap', but with a stateful step function.
concatMapAccum
    :: Monad m
    => (c -> Char -> (c, Text))
    -> c
    -> Pipe Text Text m r
concatMapAccum f = concatMapAccumM (\c w -> return (f c w))


------------------------------------------------------------------------------
-- | Similar to 'concatMapM', but with a stateful step function.
concatMapAccumM
    :: Monad m
    => (c -> Char -> m (c, Text))
    -> c
    -> Pipe Text Text m r
concatMapAccumM f = go
  where
    go c = await >>= T.foldl (\mc w -> do
        c <- mc
        (c', text) <- lift (f c w)
        yield text
        return c') (return c) >>= go


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the characters in the stream which match the
-- predicate @p@.
filter :: Monad m => (Char -> Bool) -> Pipe Text Text m r
filter = pipe . T.filter


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the characters in the stream which match the
-- monadic predicate @p@.
filterM :: Monad m => (Char -> m Bool) -> Pipe Text Text m r
filterM f = go
  where
    go = await >>= T.foldl (\m w -> do
        m
        bool <- lift (f w)
        when bool $ yield $ T.singleton w) (return ()) >> go


------------------------------------------------------------------------------
-- | @'drop' n@ discards the first @n@ charcaters from the stream.
drop :: Monad m => Int -> Pipe Text Text m ()
drop n = do
    text <- await
    let n' = n - T.length text
    if n' > 0 then drop n' else do unuse $ T.drop n text


------------------------------------------------------------------------------
-- | @'dropWhile' p@ discards characters from the stream until they no longer
-- match the predicate @p@.
dropWhile :: Monad m => (Char -> Bool) -> Pipe Text Text m ()
dropWhile p = go
  where
    go = do
        text <- await
        let (bad, good) = T.span p text
        if T.null good then go else unuse good


------------------------------------------------------------------------------
-- | @'take' n@ allows the first @n@ characters to pass through the stream,
-- and then terminates.
take :: Monad m => Int -> Pipe Text Text m ()
take n = do
    text <- await
    let n' = n - T.length text
    if n' > 0 then yield text >> take n' else do
        let (good, bad) = T.splitAt n text
        unuse bad
        yield good


------------------------------------------------------------------------------
-- | @'takeWhile' p@ allows characters to pass through the stream as long as
-- they match the predicate @p@, and terminates after the first character that
-- does not match @p@.
takeWhile :: Monad m => (Char -> Bool) -> Pipe Text Text m ()
takeWhile p = go
  where
    go = do
        text <- await
        let (good, bad) = T.span p text
        yield good
        if T.null bad then go else unuse bad


------------------------------------------------------------------------------
-- | Split the input text into lines. This makes each input chunk correspend
-- to exactly one line, even if that line was originally spread across several
-- chunks.
lines :: Monad m => Pipe Text Text m r
lines = forever $ do
    ((takeWhile (not . (== '\n')) >> return T.empty) >+> consume') >>= yield
    drop 1


------------------------------------------------------------------------------
-- | Split the input text into words. This makes each input chunk correspend
-- to exactly one word, even if that word was originally spread across several
-- chunks.
words :: Monad m => Pipe Text Text m r
words = forever $ do
    ((takeWhile (not . (== ' ')) >> return T.empty) >+> consume') >>= yield
    drop 1
