{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}

{-|

This module contains the actual implementation of the 'Pipe' concept. For an
extended introduction to the concept, see the "Control.Pipe" module.

-}

module Control.Pipe.Common
    ( -- * Types
      Pipe
    , Producer
    , Consumer
    , Pipeline

      -- * Create Pipes
      --
      -- | 'yield' and 'await' are the only two primitives you need to create
      -- 'Pipe's. Because 'Pipe' is a monad, you can assemble them using
      -- ordinary @do@ notation. Since 'Pipe' is also a monad transformer,
      -- you can use 'lift' to invoke the base monad. For example:
      --
      -- > check :: Show a => Pipe a a IO r
      -- > check = forever $ do
      -- >     x <- await
      -- >     lift $ putStrLn $ "Can " ++ (show x) ++ " pass?"
      -- >     ok <- lift $ read <$> getLine
      -- >     when ok (yield x)
    , await
    , yield
    , tryAwait
    , unuse

    , pipe
    , discard

      -- * Pipes as categories
    , PipeC (..)

      -- ** Convenience functions
      -- | The following are convenience functions that take make the
      -- 'Category' instance easier to use by automatically wrapping and
      -- unwrapping the newtype constructor.
    , (<+<)
    , (>+>)
    , idP

      -- * Run Pipes
    , runPipe
    , ($$)
    )
where

import           Control.Applicative (Applicative (..))
import           Control.Category (Category (..), (>>>), (<<<))
import           Control.Monad (ap, forever, liftM)
import           Control.Monad.Base (MonadBase (..))
import           Control.Monad.Cont.Class (MonadCont (..))
import           Control.Monad.Error.Class (MonadError (..))
import           Control.Monad.Exception.Class (MonadException (..))
import           Control.Monad.Free (Free (..))
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader.Class (MonadReader (..))
import           Control.Monad.RWS.Class (MonadRWS (..))
import           Control.Monad.State.Class (MonadState (..))
import           Control.Monad.Writer.Class (MonadWriter (..))
import           Control.Monad.Trans.Class (MonadTrans (..))
import           Data.Maybe (isNothing)
import           Prelude hiding ((.), catch, id)


------------------------------------------------------------------------------
data PipeF a b m r = M (m r) | Await (Maybe a -> r) | Yield b r | Unuse a r


------------------------------------------------------------------------------
instance Monad m => Functor (PipeF a b m) where
    fmap f (M m) = M $ liftM f m
    fmap f (Await k) = Await $ f . k
    fmap f (Yield b r) = Yield b $ f r
    fmap f (Unuse a r) = Unuse a $ f r


------------------------------------------------------------------------------
-- | The base type for pipes:
--
-- [@a@] The type of input received from upstream pipes
--
-- [@b@] The type of output delivered to downstream pipes
--
-- [@m@] The base monad
--
-- [@r@] The type of the monad's final result
--
-- The Pipe type is partly inspired by Mario Blazevic's Coroutine in his
-- concurrency article from Issue 19 of The Monad Reader and partly
-- inspired by the Trace data type from \"A Language Based Approach to
-- Unifying Events and Threads\".
newtype Pipe a b m r = Pipe (Free (PipeF a b m) r)
    deriving (Functor, Applicative, Monad)


------------------------------------------------------------------------------
instance MonadTrans (Pipe a b) where
    lift = Pipe . Free . M . liftM Pure


------------------------------------------------------------------------------
instance MonadBase b' m => MonadBase b' (Pipe a b m) where
    liftBase = lift . liftBase


------------------------------------------------------------------------------
instance MonadCont m => MonadCont (Pipe a b m) where
    callCC f = Pipe . Free . M . callCC $ \c -> do
        let Pipe pf = f (lift . c . Free . M . return . Pure) in return pf


------------------------------------------------------------------------------
instance MonadError e m => MonadError e (Pipe a b m) where
    throwError = lift . throwError
    catchError (Pipe p) h = Pipe $ go p
      where
        go (Pure r) = Pure r
        go (Free (M m)) = Free . M . catchError (liftM go m) $ \e ->
            let Pipe p' = h e in return p'
        go (Free (Await k)) = Free . Await $ go . k
        go (Free (Yield b r)) = Free . Yield b $ go r
        go (Free (Unuse a r)) = Free . Unuse a $ go r


------------------------------------------------------------------------------
instance MonadException m => MonadException (Pipe a b m) where
    throw = lift . throw
    catch (Pipe p) h = Pipe $ go p
      where
        go (Pure r) = Pure r
        go (Free (M m)) = Free . M . catch (liftM go m) $ \e ->
            let Pipe p' = h e in return p'
        go (Free (Await k)) = Free . Await $ go . k
        go (Free (Yield b r)) = Free . Yield b $ go r
        go (Free (Unuse a r)) = Free . Unuse a $ go r


------------------------------------------------------------------------------
instance MonadIO m => MonadIO (Pipe a b m) where
    liftIO = lift . liftIO


------------------------------------------------------------------------------
instance MonadReader r m => MonadReader r (Pipe a b m) where
    ask = lift ask
    local f m = m >>= lift . local f . return


------------------------------------------------------------------------------
instance MonadRWS r w s m => MonadRWS r w s (Pipe a b m)


------------------------------------------------------------------------------
instance MonadState s m => MonadState s (Pipe a b m) where
    get = lift get
    put = lift . put


------------------------------------------------------------------------------
instance MonadWriter w m => MonadWriter w (Pipe a b m) where
    tell = lift . tell
    listen m = m >>= lift . listen . return
    pass m = m >>= lift . pass . return


------------------------------------------------------------------------------
-- | A pipe that can only produce values
type Producer b m r = forall a. Pipe a b m r


------------------------------------------------------------------------------
-- | A pipe that can only consume values
type Consumer a m r = forall b. Pipe a b m r


------------------------------------------------------------------------------
-- | A self-contained pipeline that is ready to be run
type Pipeline m r = forall a b. Pipe a b m r


------------------------------------------------------------------------------
-- | Wait for input from upstream within the 'Pipe' monad. 'await' blocks
-- until input is ready and dies as soon as upstream terminates.
await :: Monad m => Consumer a m a
await = tryAwait >>= maybe discard return


------------------------------------------------------------------------------
-- | Pass output downstream within the 'Pipe' monad. 'yield' blocks until the
-- output has been received.
yield :: Monad m => b -> Producer b m ()
yield b = Pipe . Free $ Yield b (Pure ())


------------------------------------------------------------------------------
-- | A version of 'await' that does not die when upstream terminates:
-- instread, 'Nothing' is received as input.
tryAwait :: Monad m => Consumer a m (Maybe a)
tryAwait = Pipe . Free $ Await Pure


------------------------------------------------------------------------------
-- | Return unused input upstream.
unuse :: Monad m => a -> Consumer a m ()
unuse a = Pipe . Free $ Unuse a (Pure ())


------------------------------------------------------------------------------
-- | Convert a pure function into a pipe.
--
-- > pipe = forever $ do
-- >     x <- await
-- >     yield (f x)
pipe :: (Monad m) => (a -> b) -> Pipe a b m r
pipe f = forever $ await >>= yield . f


------------------------------------------------------------------------------
-- | The 'discard' pipe silently discards all input fed to it.
discard :: (Monad m) => Pipe a b m r
discard = forever await


------------------------------------------------------------------------------
-- | 'PipeC' is a newtype wrapper around 'Pipe' which reorders the type
-- variables such that it is possible to define a 'Category' instance for
-- 'Pipe'.
--
-- The 'Category' instance conforms to the category laws:
--
--     * Composition is associative (within each instance). This is not merely
--       associativity of monadic effects, but rather true associativity. The
--       result of composition produces identical composite 'Pipe's regardless
--       of how you group composition.
--
--     * 'id' is the identity 'Pipe'. Composing a 'Pipe' with 'id' returns the
--       original pipe.
--
-- The 'Category' instance prioritizes downstream effects over upstream
-- effects.
newtype PipeC m r a b = PipeC { unPipeC :: Pipe a b m r }


------------------------------------------------------------------------------
instance Monad m => Functor (PipeC m r a) where
    fmap f (PipeC p) = PipeC $ p >+> pipe f


{-
------------------------------------------------------------------------------
instance Monad m => Applicative (PipeC m r a) where
    pure = PipeC . forever . yield
    (<*>) = ??? :(
-}


------------------------------------------------------------------------------
instance Monad m => Category (PipeC m r) where
    id = PipeC $ pipe id
    PipeC (Pipe d) . PipeC (Pipe u) = PipeC $ go False False u d
      where

        -- We need two boolean parameters, one for the input of the upstream
        -- pipe, and one for its output, i.e. the input of the downstream
        -- pipe. First, if downstream does anything other than waiting, we
        -- just let the composite pipe execute the same action:

        go _ _ _ (Pure r) = return r
        go i o u (Free (Yield b d)) = yield b >> go i o u d
        go i o u (Free (M m)) = lift m >>= go i o u

        -- if upstream has not terminated yet, push unused downstream input
        -- back upstream

        go i False u (Free (Unuse a d)) = go i False (Free (Yield a u)) d
        go i True u (Free (Unuse a d)) = go i True u d

        -- then, if upstream is yielding and downstream is waiting, we can
        -- feed the yielded value to the downstream pipe and continue from
        -- there:

        go i o (Free (Yield b u)) (Free (Await k)) = go i o u $ k (Just b)

        -- if downstream is waiting and upstream is running a monadic
        -- computation, just let upstream run and keep downstream waiting:

        go i o (Free (M m)) d@(Free (Await _)) = lift m >>= flip (go i o) d

        -- more unuse stuff

        go True o (Free (Unuse a u)) d@(Free (Await _)) = go True o u d
        go False o (Free (Unuse a u)) d@(Free (Await _)) =
            unuse a >> go False o u d

        -- if upstream terminates while downstream is waiting, finalize
        -- downstream:

        go i False u@(Pure _) (Free (Await k)) = go i True u (k Nothing)

        -- but if downstream awaits again, terminate the whole composite pipe:

        go _ True (Pure r) (Free (Await _)) = return r

        -- now, if both pipes are waiting, we keep the second pipe waiting and
        -- we feed whatever input we get to the first pipe. If the input is
        -- Nothing, we set the first boolean flag, so that next time the first
        -- pipe awaits, we can finalize the downstream pipe.

        go False o (Free (Await k)) d@(Free (Await _)) =
            tryAwait >>= \x -> go (isNothing x) o (k x) d

        go True False u@(Free (Await _)) (Free (Await k)) =
            go True True u (k Nothing)

        go True True u@(Free (Await _)) d@(Free (Await _)) =
            tryAwait >>= \_ -> {- unreachable -} go True True u d


------------------------------------------------------------------------------
-- | '<+<' corresponds to '<<<'.
infixr 9 <+<
(<+<) :: (Monad m) => Pipe b c m r -> Pipe a b m r -> Pipe a c m r
p1 <+< p2 = unPipeC (PipeC p1 <<< PipeC p2)


------------------------------------------------------------------------------
-- | '>+>' corresponds '>>>'.
infixl 9 >+>
(>+>) :: (Monad m) => Pipe a b m r -> Pipe b c m r -> Pipe a c m r
(>+>) = flip (<+<)


------------------------------------------------------------------------------
-- | 'idP' corresponds to 'id'.
idP :: (Monad m) => Pipe a a m r
idP = pipe id


------------------------------------------------------------------------------
-- | Run the 'Pipe' monad transformer, converting it back into the base monad.
--
-- 'runPipe' will not work on a pipe that has loose input or output ends. If
-- your pipe is still generating unhandled output, handle it. Output is not
-- automatically 'discard'ed, because that is only one of many ways to deal
-- with unhandled output.
runPipe :: Monad m => Pipeline m r -> m r
runPipe (Pipe p) = go p
  where
    go (Pure r) = return r
    go (Free (M m)) = m >>= go
    go (Free (Await k)) = go . k $ Just undefined
    go (Free (Yield b r)) = undefined b
    go (Free (Unuse a r)) = undefined a


------------------------------------------------------------------------------
-- | To work with the equivalent of sinks, it is useful to define a source to
-- sink composition operator, '$$', which ignores the source return type, and
-- just returns the sink return value, or 'Nothing' if the source happens to
-- terminate first.
infixr 2 $$
($$) :: Monad m => Producer a m r' -> Consumer a m r -> m (Maybe r)
u $$ d = runPipe $ (u >> return Nothing) >+> liftM Just d
