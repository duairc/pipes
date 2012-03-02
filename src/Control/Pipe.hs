{-|

This library only provides a single data type: 'Pipe'.

'Pipe' is a monad transformer that extends the base monad with the ability to
'await' input from or 'yield' output to other 'Pipe's. 'Pipe's resemble
enumeratees in other libraries because they receive an input stream and
transform it into a new stream.

I'll introduce our first 'Pipe', which is a verbose version of the Prelude's
'take' function:

> take' :: Int -> Pipe a a IO ()
> take' n = do
>     replicateM_ n $ do
>         x <- await
>         yield x
>     lift $ putStrLn "You shall not pass!"

This 'Pipe' allows the first @n@ values it receives to pass through
undisturbed, then it outputs a cute message and shuts down. Shutdown is
automatic when you reach the end of the monad. You don't need to send a
special signal to connected 'Pipe's to let them know you are done handling
input or generating output.

Let's dissect the above 'Pipe''s type to learn a bit about how 'Pipe's work:

>      | Input Type | Output Type | Base monad | Return value
> Pipe   a            a             IO           ()

So @take'@ 'await's input of type @a@ from upstream 'Pipe's and 'yield's
output of type @a@ to downstream 'Pipe's. @take'@ uses 'IO' as its base monad
because it invokes the 'putStrLn' function. If we remove the call to
'putStrLn' the compiler infers the following type instead, which is
polymorphic in the base monad:

> take' :: Monad m => Int -> Pipe a a m ()

'Pipe's are conservative about using the base monad. In fact, you can only
invoke the base monad by using the 'lift' function from 'Pipe''s
'MonadTrans' instance. If you never use 'lift', your 'Pipe' will translate
into pure code.


Now let's create a function that converts a list into a 'Pipe' by 'yield'ing
each element of the list:

> fromList :: Monad m => [b] -> Pipe a b m ()
> fromList = mapM_ yield

The type signature is fully polymorphic in the input argument, as it does not
make any calls to 'await'. 'Pipe's that have don't accept any input are called
'Producers', as they only produce data and never consume it. Such pipes are
suitable for the first stage in a 'Pipeline' (see below). A type synonym is
provided for this common case:

> type Producer b m r = forall a. Pipe a b m r

You can then rewrite the type signature for @fromList@ as:

> fromList :: (Monad m) => [a] -> Producer a m ()

'Producer's correspond to what are called enumerators, or sources, in other
iteratee libraries.

Now let's create a 'Pipe' that prints every value delivered to it and never
terminates:

> printer :: Show a => Pipe a b IO b
> printer = forever $ do
>     x <- await
>     lift $ print x

This time, the type signature is fully polymorphic in the output argument, as
it does not make any calls to 'yield'. Such 'Pipe's are called 'Consumer's, as
they only consume data and never produce it. This makes them suitable for the
final stage in a 'Pipeline' (again, see below). Again, a type synonym is
provided:

> type Consumer a m r = forall b. Pipe a b m r

So we could instead write @printer@'s type as:

> printer :: (Show a) => Consumer a IO b

'Consumer's correspond to what are called iteratees, or sinks, in other
iteratee libraries.

What distinguishes 'Pipe's from every other iteratee implementation is that
they form a 'Category'. Because of this, you can literally compose 'Pipe's
into 'Pipeline's.

> newtype PipeC m r a b = PipeC { unPipeC :: Pipe a b m r }
> instance Category (PipeC m r) where ...

Unfortunately the 'PipeC' newtype is needed to reorder the type variables so
they fit into the 'Category' instance.

Using this 'Category' instance, you can compose the above 'Pipe's with:

> pipeline :: Pipe a b IO ()
> pipeline = unPipeC $ PipeC printer . PipeC (take' 3) . PipeC (fromList [1..])

As the type signature of this fully polymorhic in both its input an output
arguments, it's fully self-contained, meaning it will never 'await' any input
or 'yield' any output. Such 'Pipe's are called 'Pipeline's and a synonym is
provided:

> type Pipeline m r = forall a b. Pipe a b m r

Also, convenience functions for composing 'Pipe's without the burden of
wrapping and unwrapping newtype constructors. '<+<' corresponds to '<<<',
'>+>' corresponds to '>>>', and 'idP' corresponds to 'id'. For example:

> p1 <+< p2 = unPipeC $ PipeC p1 <<< PipeC p2 -- (<<<) is the same as (.)

So you can rewrite @pipeline@ as:

> pipeline :: Pipeline IO ()
> pipeline = printer <+< take' 3 <+< fromList [1..]

Like many other monad transformers, you convert the 'Pipe' monad back to the
base monad using some sort of \"@run...@\" function. In this case, it's the
'runPipe' function:

> runPipe :: (Monad m) => Pipeline m r -> m r

'runPipe' only works on self-contained 'Pipeline's. This (along with ('$$'),
which is a trivial wrapper around 'runPipe') is the only function in the
entire library that actually requires a 'Pipe' whose inputs and outputs are
fully polymorphic. This is to guarantee that the given 'Pipe' will never try
to 'await' or 'yield'. This is similar to the trick used in the implemtation
of the 'ST' monad.

Let's try using 'runPipe':

>>> runPipe pipeline
1
2
3
You shall not pass!

Fascinating! Our 'Pipe' terminated even though @printer@ never terminates and
@fromList@ never terminates when given an infinite list. To illustrate why our
'Pipe' terminated, let's outline the 'Pipe' flow control rules for 'Lazy'
composition:

  * Execution begins at the most downstream 'Pipe' (@printer@ in our example).

  * If a 'Pipe' 'await's input, it blocks and transfers control to the next
    'Pipe' upstream until that 'Pipe' 'yield's back a value.

  * If a 'Pipe' 'yield's output, it restores control to the original
    downstream 'Pipe' that was 'await'ing its input and binds its result to
    the return value of the 'await' command.

  * If a 'Pipe' terminates, it terminates every other 'Pipe' composed with it.

The last rule follows from laziness. If a 'Pipe' terminates then every
downstream 'Pipe' depending on its output cannot proceed, and upstream 'Pipe's
are never evaluated because the terminated 'Pipe' will not request values from
them any longer.

So in our previous example, the 'Pipeline' terminated because @take' 3@
terminated and brought down the entire 'Pipeline' with it.

'Pipe's promote loose coupling, allowing you to mix and match them
transparently using composition. For example, we can define a new 'Producer'
pipe that indefinitely prompts the user for integers:

> prompt :: Producer Int IO a
> prompt = forever $ do
>     lift $ putStrLn "Enter a number: "
>     n <- read <$> lift getLine
>     yield n

Now we can compose it with any of our previous 'Pipe's:

>>> runPipe $ printer <+< take' 3 <+< prompt
Enter a number:
1<Enter>
1
Enter a number:
2<Enter>
2
Enter a number:
3<Enter>
3
You shall not pass!

You can easily \"vertically\" concatenate 'Pipe's, 'Producer's, and
'Consumer's, all using simple monad sequencing: ('>>'). For example, here is
how you concatenate 'Producer's:

>>> runPipe $ printer <+< (fromList [1..3] >> fromList [10..12])
1
2
3
10
11
12

Here's how you would concatenate 'Consumer's:

>>> let print' n = printer <+< take' n :: (Show a) => Int -> Consumer a IO ()
>>> runPipe $ (print' 3 >> print' 4) <+< fromList [1..]
1
2
3
You shall not pass!
4
5
6
7
You shall not pass!

... but the above example is gratuitous because we could have just
concatenated the intermediate @take'@ 'Pipe':

>>> runPipe $ printer <+< (take' 3 >> take' 4) <+< fromList [1..]
1
2
3
You shall not pass!
4
5
6
7
You shall not pass!


Pipe composition imposes an important limitation: You can only compose 'Pipe's
that have the same return type. For example, I could write the following
function:

> deliver :: (Monad m) => Int -> Consumer a m [a]
> deliver n = replicateM n await

... and I might try to compose it with @fromList@:

>>> runPipe $ deliver 3 <+< fromList [1..10] -- wrong!

... but this wouldn't type-check, because @fromList@ has a return type of @()@
and @deliver@ has a return type of @[Int]@. 'Lazy' composition requires that
every 'Pipe' has a return value ready in case it terminates first. This was
not a conscious design choice, but rather a requirement of the 'Category'
instance.

Fortunately, we don't have to rewrite the @fromList@ function because we can
add a return value using vertical concatenation:

>>> runPipe $ deliver 3 <+< (fromList [1..10] >> return [])
[1,2,3]

... although a more idiomatic Haskell version would be:

>>> runPipe $ (Just <$> deliver 3) <+< (fromList [1..10] *> pure Nothing)
Just [1,2,3]

This forces you to cover all code paths by thinking about what return value
you would provide if something were to go wrong. For example, let's say I
make a mistake and request more input than @fromList@ can deliver:

>>> runPipe $ (Just <$> deliver 99) <+< (fromList [1..10] *> pure Nothing)
Nothing

The type system saved me by forcing me to handle all possible ways my program
could terminate.

A convenience operator @$$@ is provided, which is useful in cases such as
these.

> infixr 2 $$
> ($$) :: Monad m => Producer a m r' -> Consumer a m r -> m (Maybe r)

It can be used to compose @Producer@s and @Consumer@s with different return
types. It ignores the @Producer@'s type, and just returns the @Consumer@'s
return value, or else 'Nothing' if the @Producer@ happens to terminate first.


Now what if you want to write a 'Pipe' that only reads from its input end
(i.e. a 'Consumer') and returns a list of every value delivered to it when its
input 'Pipe' terminates?

> toList :: (Monad m) => Consumer a m [a]
> toList = ???

You can't write such a 'Pipe' using only 'await', because if the upstream pipe
terminates, then @toList@ is brought down with it. To handle such a case, the
'tryAwait' primitive is provided:

> tryAwait :: Monad m => Pipe a b m (Maybe a)

If the upstream pipe is still running, 'tryAwait' behaves exactly like
'await'. However, when the upstream pipe terminates, 'tryAwait' stays up and
receives 'Nothing', allowing us to tidy up after upstream terminates. @toList@
can now be written like this:

> toList :: Monad m => Pipe a b m [a]
> toList = tryAwait >>= go id
>   where
>     go dlist Nothing = return $ dlist []
>     go dlist (Just a) = tryAwait >>= go (dlist . (a:))


Note that a terminated 'Pipe' only brings down 'Pipe's composed with it. To
illustrate this, let's use the following example:

> p = do a <+< b
>        c

@a@, @b@, and @c@ are 'Pipe's, and @c@ shares the same input and output as
@a <+< b@, otherwise we cannot combine them within the same monad. In the
above example, either @a@ or @b@ could terminate and bring down the other one
since they are composed, but @c@ is guaranteed to continue after @a <+< b@
terminates because it is not composed with them. Conceptually, we can think of
this as @c@ automatically taking over the 'Pipe''s channeling responsibilities
when @a <+< b@ can no longer continue. There is no need to \"restart\" the
input or output manually as in some other iteratee libraries.

The @pipes@ library, unlike other iteratee libraries, grounds its vertical and
horizontal concatenation in mathematics by deriving horizontal concatenation
('.') from 'Category' instance and vertical concatenation ('>>') from its
'Monad' instance. This makes it easier to reason about 'Pipe's because you can
leverage your intuition about 'Category's and 'Monad's to understand their
behavior. The only 'Pipe'-specific primitives are the 'await' and 'yield'
functions.

It is important to note that unlike some other iteratee libraries, @pipes@
does not try to automatically handle resource finalisation, as this is
orthogonal to the iteratee problem.

For example, let's say we have the file \"test.txt\" with the following
contents:

> This is a test.
> Don't panic!
> Calm down, please!

and a producer which, given a file, will open that file and read a line at a
time before closing it:

> readLines :: FilePath -> Producer String IO ()
> readLines file = do
>     lift $ putStrLn "Opening file..."
>     h <- lift $ openFile file ReadMode
>     go h
>     lift $ putStrLn "Closing file..."
>     lift $ hClose h
>   where
>     go h = do
>         eof <- lift $ hIsEOF h
>         unless eof $ do
>             s <- lift $ hGetLine h
>             yield s
>             go h

Now compose!

>>> runPipe $ printer <+< readLines "test.txt"
Opening file...
"This is a test."
"Don't panic!"
"Calm down, please!"
Closing file...

Everything works as expected. However, if we were to read only the first two
lines of the file:

>>> runPipe $ printer <+< take' 2 <+< readLines "test.txt"
Opening file...
"This is a test."
"Don't panic!"

then we run into a problem: the file is never closed! One solution to this is
to make sure that every pipe in the pipeline consumes all of its input. For
example, the following will work as expected:

>>> runPipe $ printer <+< (take' 2 >> discard) <+< readLines "test.txt"
Opening file...
"This is a test."
"Don't panic!"
Closing file...

However, this is unsatisfactory, as it means that the entire contents of the
file must be read, even when only a small fraction of its contents are needed.
The recommended solution to this is to use the 'ResourceT' transformer.
'ResourceT' was originally developed as part of the @conduit@ package, another
iteratee library, but a simplified standalone version is available from the
@resource-simple@ package.

Using 'ResourceT', our @readLines@ example becomes:

> readLines :: FilePath -> Producer String (ResourceT IO) ()
> readLines file = do
>     (key, h) <- lift $ with
>         (putStrLn "Opening file..." >> openFile file ReadMode)
>         (\h -> putStrLn "Closing file..." >> hClose h)
>     go h
>     lift $ release key
>   where
>     go h = do
>         eof <- lift . lift $ hIsEOF h
>         unless eof $ do
>             s <- lift . lift $ hGetLine h
>             yield s
>             go h

>>> runResourceT . runPipe $ printer <+< take' 2 <+< readLines "test.txt"
Opening file...
"This is a test."
"Don't panic!"
Closing file...

Perfect! Although note that for that composition to type-check, the @printer@
pipe would need to be rewritten to work on arbitrary @MonadIO@ instances. This
is trivial however, so I will not include it here.

One last example: what if we wanted to write a 'Consumer' that would consume
chunks of input until it reached a newline character, and then return the
concatenation of all input received before the newline character? The problem
here is what to do with leftover input. If a chunk is received that contains a
newline character, but also other characters after the newline, we would like
to \"return\" the characters after the newline upstream, as we don't use them.
The 'unuse' primitive is provided to handle this case.

> getLine' :: Monad m => Pipe String b m String
> getLine' = go ""
>   where
>     go leftover = tryAwait >>= maybe (return leftover) (split leftover)
>     split leftover chunk
>         | null chunk = go leftover
>         | null rest = go $ leftover ++ chunk
>         | otherwise = do
>             unless (null rest') $ unuse rest'
>             return $ leftover ++ line
>       where
>         (line, rest) = break (== '\n') chunk
>         rest' = drop 1 rest

-}

module Control.Pipe
    ( module Control.Pipe.Common
    )
where

import           Control.Category
import           Control.Monad.Trans.Class
import           Control.Pipe.Common
