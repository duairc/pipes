{-# LANGUAGE BangPatterns #-}

{-|

Higher-level functions to interact with the elements of a stream. Most of
these are based on list functions.

Note that these functions all deal with individual elements of a stream as a
sort of \"black box\", where there is no introspection of the contained
elements. Values such as @ByteString@ and @Text@ will likely need to be
treated specially to deal with their contents properly (@Word8@ and @Char@,
respectively). See the "Control.Pipe.Binary" and "Control.Pipe.Text" modules
for such 'Pipe's.

-}

module Control.Pipe.List
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
    , nub
    , groupBy

{-
      -- ** Zipping
    , zip
    , zip3
    , zip4
    , zip5
    , zip6
    , zip7
    , zipWith
    , zipWith3
    , zipWith4
    , zipWith5
    , zipWith6
    , zipWith7
-}
    )
where

--import           Control.Applicative ((<$>), (<*>))
import           Control.Monad (Monad (..), (=<<), forever, when)
import qualified Control.Monad as L (mapM_, replicateM_)
import           Control.Monad.Trans.Class (lift)
import           Control.Pipe.Common
import           Data.Function (($), (.), id)
import           Data.Maybe (Maybe (..), maybe)
import qualified Data.Set as S
import           Prelude (Bool, Int, Ord)


------------------------------------------------------------------------------
-- | Produce a stream of values from a given list.
produce :: Monad m => [a] -> Producer a m ()
produce = L.mapM_ yield


------------------------------------------------------------------------------
-- | @'iterate' f x@ produces an infinite stream of repeated applications of
-- @f@ to @x@.
iterate :: Monad m => (a -> a) -> a -> Producer a m b
iterate f = go
  where
    go !a = yield a >> go (f a)


------------------------------------------------------------------------------
-- | Similar to 'iterate', except the iteration function is monadic.
iterateM :: Monad m => (a -> m a) -> a -> Producer a m b
iterateM f = go
  where
    go !a = yield a >> lift (f a) >>= go


------------------------------------------------------------------------------
-- | Produces an infinite stream of a single value.
repeat :: Monad m => a -> Producer a m b
repeat = forever . yield


------------------------------------------------------------------------------
-- | Produces an infinite stream of values. Each value is computed by the
-- underlying monad.
repeatM :: Monad m => m a -> Producer a m b
repeatM a = forever $ lift a >>= yield


------------------------------------------------------------------------------
-- | @'replicate' n x@ produces a stream containing @n@ copies of @x@.
replicate :: Monad m => Int -> a -> Producer a m ()
replicate n = L.replicateM_ n . yield


------------------------------------------------------------------------------
-- | @'replicateM' n x@ produces a stream containing @n@ values. Each value is
-- computed by the underlying monad.
replicateM :: Monad m => Int -> m a -> Producer a m ()
replicateM n a = L.replicateM_ n $ lift a >>= yield


------------------------------------------------------------------------------
-- | Produces a stream of values by repeatedly applying a function to some
-- state, until 'Nothing' is returned.
unfold :: Monad m => (c -> Maybe (a, c)) -> c -> Producer a m ()
unfold f = go
  where
    go !c = maybe (return ()) (\(a, c') -> yield a >> go c') (f c)


------------------------------------------------------------------------------
-- | Produces a stream of values by repeatedly applying a computation to some
-- state, until 'Nothing' is returned.
unfoldM :: Monad m => (c -> m (Maybe (a, c))) -> c -> Producer a m ()
unfoldM f = go
  where
    go !c = lift (f c) >>= maybe (return ()) (\(a, c') -> yield a >> go c')


------------------------------------------------------------------------------
-- | Consume a stream of values and return them in a list.
consume :: Monad m => Consumer a m [a]
consume = tryAwait >>= go id
  where
    go dlist Nothing = return $ dlist []
    go dlist (Just x) = tryAwait >>= go (dlist . (x:))


------------------------------------------------------------------------------
-- | A strict left fold.
fold :: Monad m => (b -> a -> b) -> b -> Consumer a m b
fold f = go
  where
    go !b = tryAwait >>= maybe (return b) (go . f b)


------------------------------------------------------------------------------
-- | A monadic strict left fold.
foldM :: Monad m => (b -> a -> m b) -> b -> Consumer a m b
foldM f = go
  where
    go !b = tryAwait >>= maybe (return b) ((go =<<) . lift . f b)


------------------------------------------------------------------------------
-- | For every value in a stream, run a computation and discard its result.
mapM_ :: Monad m => (a -> m b) -> Consumer a m r
mapM_ f = forever $ await >>= lift . f


------------------------------------------------------------------------------
-- | Apply a transformation to all values in a stream.
map :: Monad m => (a -> b) -> Pipe a b m r
map = pipe


------------------------------------------------------------------------------
-- | Apply a monadic transformation to all values in a stream.
mapM :: Monad m => (a -> m b) -> Pipe a b m r
mapM f = forever $ await >>= lift . f >>= yield


------------------------------------------------------------------------------
-- | Apply a transformation to all values in a stream, concatenating the
-- output values.
concatMap :: Monad m => (a -> [b]) -> Pipe a b m r
concatMap f = forever $ await >>= produce . f


------------------------------------------------------------------------------
-- | Apply a monadic transformation to all values in a stream, concatenating
-- the output values.
concatMapM :: Monad m => (a -> m [b]) -> Pipe a b m r
concatMapM f = forever $ await >>= lift . f >>= produce


------------------------------------------------------------------------------
-- | Similar to 'map', but with a stateful step function.
mapAccum :: Monad m => (c -> a -> (c, b)) -> c -> Pipe a b m r
mapAccum f = go
  where
    go !c = await >>= \a -> let (c', b) = f c a in yield b >> go c'


------------------------------------------------------------------------------
-- | Similar to 'mapM', but with a stateful step function.
mapAccumM :: Monad m => (c -> a -> m (c, b)) -> c -> Pipe a b m r
mapAccumM f = go
  where
    go !c = await >>= lift . f c >>= \(c', b) -> yield b >> go c'


------------------------------------------------------------------------------
-- | Similar to 'concatMap', but with a stateful step function.
concatMapAccum :: Monad m => (c -> a -> (c, [b])) -> c -> Pipe a b m r
concatMapAccum f = go
  where
    go !c = await >>= \a -> let (c', b) = f c a in produce b >> go c'


------------------------------------------------------------------------------
-- | Similar to 'concatMapM', but with a stateful step function.
concatMapAccumM f = go
  where
    go !c = await >>= lift . f c >>= \(c', b) -> produce b >> go c'


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the values in the stream which match the
-- predicate @p@.
filter :: Monad m => (a -> Bool) -> Pipe a a m r
filter f = forever $ await >>= \a -> when (f a) (yield a)


------------------------------------------------------------------------------
-- | @'filter' p@ keeps only the values in the stream which match the monadic
-- predicate @p@.
filterM :: Monad m => (a -> m Bool) -> Pipe a a m r
filterM f = forever $ await >>= \a -> lift (f a) >>= \b -> when b (yield a)


------------------------------------------------------------------------------
-- | @'drop' n@ discards the first @n@ input values from the stream.
drop :: Monad m => Int -> Pipe a a m ()
drop n = L.replicateM_ n await


------------------------------------------------------------------------------
-- | @'dropWhile' p@ discards values from the stream until they no longer
-- match the predicate @p@.
dropWhile :: Monad m => (a -> Bool) -> Pipe a a m ()
dropWhile p = go
  where
    go = await >>= \a -> if p a then go else unuse a


------------------------------------------------------------------------------
-- | @'take' n@ allows the first @n@ values to pass through the stream, and
-- then terminates.
take :: Monad m => Int -> Pipe a a m ()
take n = L.replicateM_ n $ await >>= yield


------------------------------------------------------------------------------
-- | @'takeWhile' p@ allows values to pass through the stream as long as they
-- match the predicate @p@, and terminates after the first value that does not
-- match @p@.
takeWhile :: Monad m => (a -> Bool) -> Pipe a a m ()
takeWhile p = go
  where
    go = await >>= \a -> if p a then yield a >> go else unuse a


------------------------------------------------------------------------------
-- | Remove duplicate values from a stream, passing through the first instance
-- of each value. 'Data.Set.Set' is used internally for efficiency.
nub :: (Ord a, Monad m) => Pipe a a m r
nub = go S.empty
  where
    go !s = await >>= \a -> if S.member a s
        then go s
        else yield a >> go (S.insert a s)


------------------------------------------------------------------------------
-- | Group input according to a given equality function.
groupBy :: Monad m => (a -> a -> Bool) -> Pipe a [a] m r
groupBy (==) = await >>= \a -> go (a:) a
  where
    go dlist a = tryAwait >>= maybe (yield (dlist []) >> discard) (\a' ->
        if a == a'
            then go (dlist . (a':)) a
            else yield (dlist []) >> go (a':) a')


{-
------------------------------------------------------------------------------
zip :: Monad m => Pipe a b m r -> Pipe a b' m r -> Pipe a (b, b') m r
zip = zipWith (,)


------------------------------------------------------------------------------
zip3
    :: Monad m
    => Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a (b, b', b'') m r
zip3 = zipWith3 (,,)


------------------------------------------------------------------------------
zip4
    :: Monad m
    => Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a (b, b', b'', b''') m r
zip4 = zipWith4 (,,,)


------------------------------------------------------------------------------
zip5
    :: Monad m
    => Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a (b, b', b'', b''', b'''') m r
zip5 = zipWith5 (,,,,)


------------------------------------------------------------------------------
zip6
    :: Monad m
    => Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a b''''' m r
    -> Pipe a (b, b', b'', b''', b'''', b''''') m r
zip6 = zipWith6 (,,,,,)


------------------------------------------------------------------------------
zip7
    :: Monad m
    => Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a b''''' m r
    -> Pipe a b'''''' m r
    -> Pipe a (b, b', b'', b''', b'''', b''''', b'''''') m r
zip7 = zipWith7 (,,,,,,)


------------------------------------------------------------------------------
zipWith
    :: Monad m
    => (b -> b' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a c m r
zipWith f p p' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'


------------------------------------------------------------------------------
zipWith3
    :: Monad m
    => (b -> b' -> b'' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a c m r
zipWith3 f p p' p'' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'
    <*> PipeC p''


------------------------------------------------------------------------------
zipWith4
    :: Monad m
    => (b -> b' -> b'' -> b''' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a c m r
zipWith4 f p p' p'' p''' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'
    <*> PipeC p''
    <*> PipeC p'''


------------------------------------------------------------------------------
zipWith5
    :: Monad m
    => (b -> b' -> b'' -> b''' -> b'''' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a c m r
zipWith5 f p p' p'' p''' p'''' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'
    <*> PipeC p''
    <*> PipeC p'''
    <*> PipeC p''''


------------------------------------------------------------------------------
zipWith6
    :: Monad m
    => (b -> b' -> b'' -> b''' -> b'''' -> b''''' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a b''''' m r
    -> Pipe a c m r
zipWith6 f p p' p'' p''' p'''' p''''' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'
    <*> PipeC p''
    <*> PipeC p'''
    <*> PipeC p''''
    <*> PipeC p'''''


------------------------------------------------------------------------------
zipWith7
    :: Monad m
    => (b -> b' -> b'' -> b''' -> b'''' -> b''''' -> b'''''' -> c)
    -> Pipe a b m r
    -> Pipe a b' m r
    -> Pipe a b'' m r
    -> Pipe a b''' m r
    -> Pipe a b'''' m r
    -> Pipe a b''''' m r
    -> Pipe a b'''''' m r
    -> Pipe a c m r
zipWith7 f p p' p'' p''' p'''' p''''' p'''''' = unPipeC $ f
    <$> PipeC p
    <*> PipeC p'
    <*> PipeC p''
    <*> PipeC p'''
    <*> PipeC p''''
    <*> PipeC p'''''
    <*> PipeC p''''''
-}
