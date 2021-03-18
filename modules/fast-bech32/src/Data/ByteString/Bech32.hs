-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Data.ByteString.Bech32
    ( -- * Encoding
      encodeBech32

      -- * HumanReadablePart
    , HumanReadablePart(HumanReadablePart)
    , pattern HumanReadablePartConstr
    , unHumanReadablePart
    ) where

import Relude

import Data.Bits
    ( complement, shiftL, shiftR, testBit, xor, (.&.) )
import Data.ByteString.Internal
    ( ByteString (..) )
import Foreign.ForeignPtr
    ( withForeignPtr )
import Foreign.Ptr
    ( Ptr, plusPtr )
import Foreign.Storable
    ( peek, poke )
import GHC.Exts
    ( Addr#, indexWord8OffAddr#, word2Int# )
import GHC.ForeignPtr
    ( mallocPlainForeignPtrBytes )
import GHC.Word
    ( Word8 (..) )
import System.IO.Unsafe
    ( unsafeDupablePerformIO )

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

-- | Encode some binary data to bech32 using the given human readable prefix.
encodeBech32 :: HumanReadablePart -> ByteString -> Text
encodeBech32 hrp bytes =
    let
        (chk, dp) = encodeDataPart alphabet (chkHead hrp) bytes
    in
        raw hrp <> "1" <> dp <> encodeChecksum alphabet chk
  where
    alphabet :: Addr#
    alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"#

--
-- HumanReadablePart
--

data HumanReadablePart = HumanReadablePartConstr
    { raw :: !Text
    , chkHead :: !Checksum
    } deriving Show

-- | Construct a human readable part from a text string, and pre-calculate the
-- checksum corresponding to it.
pattern HumanReadablePart :: Text -> HumanReadablePart
pattern HumanReadablePart { unHumanReadablePart } <-
    HumanReadablePartConstr unHumanReadablePart _
  where
    HumanReadablePart raw =
        let
            chkHead = foldl' polymodStep (Checksum 1) $ expand (T.unpack raw)

            expand :: [Char] -> [Word5]
            expand xs =
                [ coerce (fromIntegral @_ @Word8 (ord x) `shiftR` 5) | x <- xs ]
                ++
                [Word5 0]
                ++
                [ coerce (fromIntegral @_ @Word8 (ord x) .&. 31) | x <- xs ]
        in
            HumanReadablePartConstr {raw,chkHead}

{-# COMPLETE HumanReadablePart #-}

--
-- Main encoding loop
--

encodeDataPart :: Addr# -> Checksum -> ByteString -> (Checksum, Text)
encodeDataPart !alphabet !chk0 =
    withAllocatedPointers (base32 0 (Residue 0) chk0)
  where
    withAllocatedPointers
        :: (Int -> Ptr Word8 -> Ptr Word8 -> IO Checksum)
        -> ByteString
        -> (Checksum, Text)
    withAllocatedPointers fn (PS !inputForeignPtr !_ !inputLen) =
        let (!q, !r) = (inputLen * 8) `quotRem` 5 in
        let resultLen = q + if r == 0 then 0 else 1 in
        unsafeDupablePerformIO $ do
            resultForeignPtr <- mallocPlainForeignPtrBytes resultLen
            withForeignPtr resultForeignPtr $ \resultPtr ->
                withForeignPtr inputForeignPtr $ \inputPtr -> do
                    chk' <- fn (resultLen - 1) inputPtr resultPtr
                    return
                        ( chk'
                        , T.decodeUtf8 $ PS resultForeignPtr 0 resultLen
                        )

    base32 :: Int -> Residue -> Checksum -> Int -> Ptr Word8 -> Ptr Word8 -> IO Checksum
    base32 !n !r !chk !maxN !inputPtr !resultPtr
        | n >= maxN = do
            let w = coerce @Word8 @Word5 (coerce r)
            poke resultPtr (alphabet `lookupWord5` w)
            return $ polymodStep chk w
        | otherwise = do
            (w, r', inputPtr') <- peekWord5 n r inputPtr
            poke resultPtr (alphabet `lookupWord5` w)
            let chk' = polymodStep chk w
            base32 (n+1) r' chk' maxN inputPtr' (plusPtr resultPtr 1)

--
-- Checksum
--

newtype Checksum
    = Checksum Word
    deriving Show

encodeChecksum :: Addr# -> Checksum -> Text
encodeChecksum alphabet chk =
    [ alphabet `lookupWord5` word5 (polymod `shiftR` i)
    | i <- [25, 20 .. 0 ]
    ] & T.decodeUtf8 . BS.pack
  where
    polymod = (coerce (foldl' polymodStep chk tailBytes) .&. 0x3fffffff) `xor` 1

tailBytes :: [Word5]
tailBytes =
    [ coerce @Word8 @Word5 0
    , coerce @Word8 @Word5 0
    , coerce @Word8 @Word5 0
    , coerce @Word8 @Word5 0
    , coerce @Word8 @Word5 0
    , coerce @Word8 @Word5 0
    ]
{-# INLINE tailBytes #-}

polymodStep :: Checksum -> Word5 -> Checksum
polymodStep (coerce -> (chk :: Word)) (coerce -> v) =
    let chk' = (chk `shiftL` 5) `xor` fromIntegral (v :: Word8) in
    chk' & xor (if testBit chk 25 then 0x3b6a57b2 else 0)
         & xor (if testBit chk 26 then 0x26508e6d else 0)
         & xor (if testBit chk 27 then 0x1ea119fa else 0)
         & xor (if testBit chk 28 then 0x3d4233dd else 0)
         & xor (if testBit chk 29 then 0x2a1462b3 else 0)
         & coerce

--
-- Word5
--

newtype Word5
    = Word5 Word8
    deriving Show

newtype Residue
    = Residue Word8
    deriving Show

word5 :: Word -> Word5
word5 = coerce . fromIntegral @Word @Word8 . (.&. 31)
{-# INLINE word5 #-}

-- | Fast array lookup of a word5 in an unboxed bytestring.
lookupWord5 :: Addr# -> Word5 -> Word8
lookupWord5 table (Word5 (W8# i)) =
    W8# (indexWord8OffAddr# table (word2Int# i))
{-# INLINE lookupWord5 #-}

-- | Lookup a Word5 using the given pointer and a previous 'Residue'. Returns
-- the looked up 'Word5', a 'Residue' and the pointer advanced to the next
-- word;
peekWord5 :: Int -> Residue -> Ptr Word8 -> IO (Word5, Residue, Ptr Word8)
peekWord5 n r ptr
    | i == 0 = do
        w <- peek ptr
        let mask = 0b11111000 :: Word8
        return
            ( coerce ((w .&. mask) `shiftR` 3)
            , coerce ((w .&. complement mask) `shiftL` 2)
            , plusPtr ptr 1
            )
    | i == 1 = do
        w <- peek ptr
        let mask = 0b11000000 :: Word8
        return
            ( coerce (((w .&. mask) `shiftR` 6) + coerce r)
            , coerce (w .&. complement mask)
            , plusPtr ptr 1
            )
    | i == 2 = do
        let mask = 0b00111110 :: Word8
        return
            ( coerce ((coerce r .&. mask) `shiftR` 1)
            , coerce ((coerce r .&. complement mask) `shiftL` 4)
            , ptr
            )
    | i == 3 = do
        w <- peek ptr
        let mask = 0b11110000 :: Word8
        return
            ( coerce (((w .&. mask) `shiftR` 4) + coerce r)
            , coerce ((w .&. complement mask) `shiftL` 1)
            , plusPtr ptr 1
            )
    | i == 4 = do
        w <- peek ptr
        let mask = 0b10000000 :: Word8
        return
            ( coerce (((w .&. mask) `shiftR` 7) + coerce r)
            , coerce (w .&. complement mask)
            , plusPtr ptr 1
            )
    | i == 5 = do
        let mask = 0b01111100 :: Word8
        return
            ( coerce ((coerce r .&. mask) `shiftR` 2)
            , coerce ((coerce r .&. complement mask) `shiftL` 3)
            , ptr
            )
    | i == 6 = do
        w <- peek ptr
        let mask = 0b11100000 :: Word8
        return
            ( coerce (((w .&. mask) `shiftR` 5) + coerce r)
            , coerce (w .&. complement mask)
            , plusPtr ptr 1
            )
    | otherwise = do
        return
            ( coerce r
            , coerce (0 :: Word8)
            , ptr
            )
  where
    i = n `mod` 8
