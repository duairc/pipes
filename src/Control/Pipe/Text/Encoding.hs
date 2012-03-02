{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

{-|

This module exports 'Pipe's for converting between streams of 'ByteString's 
and streams of 'Text's.

-}

module Control.Pipe.Text.Encoding
    ( -- * Encoding and decoding
      encode
    , decode

      -- * 'TextEncoding'
      -- ** Re-exported from "System.IO"
    , TextEncoding
    , utf8
    , utf16le
    , utf16be
    , utf32le
    , utf32be
    , latin1

      -- * 'UnicodeException'
      -- ** Re-exported from "Data.Text.Encoding.Error"
    , UnicodeException (..)
    )
where

import           Control.Arrow (first)
import           Control.Exception (evaluate, try)
import           Control.Monad (forever, unless)
import           Control.Monad.Exception.Class
import           Control.Pipe.Common
import           Data.Bits ((.&.), (.|.), shiftL)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import           Data.Char (ord)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.Text.Encoding.Error (UnicodeException (..))
import           Data.Word (Word8, Word16)
import           System.IO
                     ( TextEncoding
                     , utf8
                     , utf16le
                     , utf16be
                     , utf32le
                     , utf32be
                     , latin1
                     )
import           System.IO.Unsafe (unsafePerformIO)


------------------------------------------------------------------------------
-- | Convert text into bytes, using the provided 'TextEncoding'. If the
-- encoding is not capable of representing an input character, a
-- 'UnicodeException' will be thrown.
encode :: MonadException m => TextEncoding -> Pipe Text ByteString m r
encode encoding = do
    let encoder = encodeWith encoding
    forever $ do
        text <- await
        let (bs, m) = encoder text
        unless (B.null bs) $ yield bs
        maybe (return ()) throw m


------------------------------------------------------------------------------
-- | Convert bytes into text, using the provided 'TextEncoding'. If the
-- encoding is not capable of representing an input character, a
-- 'UnicodeException' will be thrown.
decode :: MonadException m => TextEncoding -> Pipe ByteString Text m r
decode encoding = go B.empty
  where
    decoder = decodeWith encoding
    go leftover = do
        bs <- await
        let (text, e) = decoder $ B.append leftover bs
        unless (T.null text) $ yield text
        either throw return e >>= go


------------------------------------------------------------------------------
encodeWith :: TextEncoding -> Text -> (ByteString, Maybe UnicodeException)
encodeWith encoding
    | show encoding == show utf8 = \text ->
        (TE.encodeUtf8 text, Nothing)
    | show encoding == show utf16le = \text ->
        (TE.encodeUtf16LE text, Nothing)
    | show encoding == show utf16be = \text ->
        (TE.encodeUtf16BE text, Nothing)
    | show encoding == show utf32le = \text ->
        (TE.encodeUtf32LE text, Nothing)
    | show encoding == show utf32be = \text ->
        (TE.encodeUtf32BE text, Nothing)
    | show encoding == show latin1 = \text -> do
        let (good, bad) = T.span (\c -> ord c <= 0xFF) text
        let bs = B8.pack (T.unpack good)
        let error = if T.null bad
            then Nothing
            else Just $ EncodeError (show latin1) (T.find (const True) bad)
        (bs, error)
    | otherwise = error $ "Control.Text.Encoding.encodeWith: The \"" ++ show
          encoding ++ "\" TextEncoding is not supported."


------------------------------------------------------------------------------
decodeWith :: TextEncoding -> ByteString -> (Text, Either UnicodeException ByteString)
decodeWith encoding
    | show encoding == show utf8 = \bs -> do
        let splitQuickly = go 0 >>= tryMaybe
              where
                required x
                    | x .&. 0x80 == 0x00 = 1
                    | x .&. 0xE0 == 0xC0 = 2
                    | x .&. 0xF0 == 0xE0 = 3
                    | x .&. 0xF8 == 0xF0 = 4
                    | otherwise = 0
                maxN = B.length bs
                go n = if n == maxN then Just (TE.decodeUtf8 bs, B.empty)
                    else do
                        let x = B.index bs n
                        let split = B.splitAt n bs
                        if required x == 0
                            then Nothing
                            else if n + required x > maxN
                                then Just $ first TE.decodeUtf8 split
                                else go $ n + required x
        case splitQuickly of
            Just (text, extra) -> (text, Right extra)
            Nothing -> splitSlowly TE.decodeUtf8 bs
    | show encoding == show utf16le = \bs -> do
        let splitQuickly = tryMaybe (go 0)
              where
                maxN = B.length bs
                decodeTo n = first TE.decodeUtf16LE (B.splitAt n bs)
                go n = if n == maxN || n + 1 == maxN
                    then decodeTo n
                    else do
                        let req = utf16Req (B.index bs n) (B.index bs (n + 1))
                        if n + req > maxN
                            then decodeTo n
                            else go $ n + req
        case splitQuickly of
            Just (text, extra) -> (text, Right extra)
            Nothing -> splitSlowly TE.decodeUtf16LE bs   
    | show encoding == show utf16be = \bs -> do
        let splitQuickly = tryMaybe (go 0)
              where
                maxN = B.length bs
                decodeTo n = first TE.decodeUtf16BE (B.splitAt n bs)
                go n = if n == maxN || n + 1 == maxN
                    then decodeTo n
                    else do
                        let req = utf16Req (B.index bs (n + 1)) (B.index bs n)
                        if n + req > maxN
                            then decodeTo n
                            else go $ n + req
        case splitQuickly of
            Just (text, extra) -> (text, Right extra)
            Nothing -> splitSlowly TE.decodeUtf16BE bs
    | show encoding == show utf32le = \bs -> do
        case utf32Split TE.decodeUtf32LE bs of
            Just (text, extra) -> (text, Right extra)
            Nothing -> splitSlowly TE.decodeUtf32LE bs
    | show encoding == show utf32be = \bs -> do
        case utf32Split TE.decodeUtf32BE bs of
            Just (text, extra) -> (text, Right extra)
            Nothing -> splitSlowly TE.decodeUtf32BE bs
    | show encoding == show latin1 = \bs -> do
        (T.pack (B8.unpack bs), Right B.empty)
    | otherwise = error $ "Control.Text.Encoding.getDecode: The \"" ++
          show encoding ++ "\" TextEncoding is not supported."


------------------------------------------------------------------------------
safely :: a -> Either UnicodeException a
safely = unsafePerformIO . try . evaluate


------------------------------------------------------------------------------
tryMaybe :: (a, b) -> Maybe (a, b)
tryMaybe (a, b) = either (const Nothing) Just $ safely a >>= \a' -> do
    return (a', b)


------------------------------------------------------------------------------
splitSlowly
    :: (ByteString -> Text)
    -> ByteString -> (Text, Either UnicodeException ByteString)
splitSlowly decoder bs = go (B.length bs)
  where
    getError x = fmap (const x) (safely $ decoder x)
    go 0 = (T.empty, getError bs)
    go n = do
        let (a, b) = B.splitAt n bs
        let e = safely $ decoder a
        either (const $ go (n - 1)) (\text -> (text, getError b)) e


------------------------------------------------------------------------------
utf16Req :: Word8 -> Word8 -> Int
utf16Req x0 x1 = if x >= 0xD800 && x <= 0xDBFF then 4 else 2
  where
    x :: Word16
    x = (fromIntegral x1 `shiftL` 8) .|. fromIntegral x0


------------------------------------------------------------------------------
utf32Split :: (ByteString -> Text) -> ByteString -> Maybe (Text, ByteString)
utf32Split decoder bs = tryMaybe split
  where
    split = first decoder $ B.splitAt (let l = B.length bs in l - mod l 4) bs
