-- |
--   Copyright   :  (c) Sam Truzjan 2013
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   Normally peer to peer communication consisting of the following
--   steps:
--
--   * In order to establish the connection between peers we should
--   send 'Handshake' message. The 'Handshake' is a required message
--   and must be the first message transmitted by the peer to the
--   another peer. Another peer should reply with a handshake as well.
--
--   * Next peer might sent bitfield message, but might not. In the
--   former case we should update bitfield peer have. Again, if we
--   have some pieces we should send bitfield. Normally bitfield
--   message should sent after the handshake message.
--
--   * Regular exchange messages. TODO docs
--
--   For more high level API see "Network.BitTorrent.Exchange" module.
--
--   For more infomation see:
--   <https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29>
--
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# OPTIONS  -fno-warn-orphans  #-}
module Network.BitTorrent.Exchange.Message
       ( -- * Capabilities
         Extension (..)
       , Caps
       , toCaps
       , fromCaps
       , allowed

         -- * Handshake
       , Handshake(..)
       , defaultHandshake
       , defaultBTProtocol
       , handshakeSize
       , handshakeMaxSize

         -- * Messages
       , Message        (..)
       , PeerMessage    (..)
       , requires

         -- ** Core messages
       , StatusUpdate   (..)
       , RegularMessage (..)

         -- ** Fast extension
       , FastMessage    (..)

         -- ** Extension protocol
       , ExtendedMessage   (..)
       , ExtendedExtension
       , ExtendedCaps      (..)
       , ExtendedHandshake (..)
       , ExtendedMetadata  (..)
       ) where

import Control.Applicative
import Data.BEncode as BE
import Data.BEncode.BDict as BE
import Data.BEncode.Internal (ppBEncode)
import Data.Bits
import Data.ByteString as BS
import Data.ByteString.Char8 as BC
import Data.ByteString.Lazy  as BL
import Data.Default
import Data.IntMap as IM
import Data.List as L
import Data.Monoid
import Data.Ord
import Data.Serialize as S
import Data.Text as T
import Data.Typeable
import Data.Word
import Network
import Network.Socket hiding (KeepAlive)
import Text.PrettyPrint as PP
import Text.PrettyPrint.Class

import Data.Torrent.Bitfield
import Data.Torrent.InfoHash
import Network.BitTorrent.Core
import Network.BitTorrent.Exchange.Block

{-----------------------------------------------------------------------
--  Extensions
-----------------------------------------------------------------------}

--  | See <http://www.bittorrent.org/beps/bep_0004.html> for more
--  information.
--
data Extension
  = ExtDHT      -- ^ BEP 5
  | ExtFast     -- ^ BEP 6
  | ExtExtended -- ^ BEP 10
    deriving (Show, Eq, Ord, Enum, Bounded)

instance Pretty Extension where
  pretty ExtDHT      = "DHT"
  pretty ExtFast     = "Fast Extension"
  pretty ExtExtended = "Extension Protocol"

capMask :: Extension -> Caps
capMask ExtDHT      = Caps 0x01
capMask ExtFast     = Caps 0x04
capMask ExtExtended = Caps 0x100000

{-----------------------------------------------------------------------
--  Capabilities
-----------------------------------------------------------------------}

-- | A set of 'Extension's.
newtype Caps = Caps { unCaps :: Word64 }
  deriving (Show, Eq)

instance Pretty Caps where
  pretty = hcat . punctuate ", " . L.map pretty . fromCaps

instance Default Caps where
  def = Caps 0
  {-# INLINE def #-}

instance Monoid Caps where
  mempty  = Caps (-1)
  {-# INLINE mempty #-}

  mappend (Caps a) (Caps b) = Caps (a .&. b)
  {-# INLINE mappend #-}

instance Serialize Caps where
  put (Caps caps) = S.putWord64be caps
  {-# INLINE put #-}

  get = Caps <$> S.getWord64be
  {-# INLINE get #-}

allowed :: Caps -> Extension -> Bool
allowed (Caps caps) = testMask . capMask
  where
    testMask (Caps bits) = (bits .&. caps) == bits

toCaps :: [Extension] -> Caps
toCaps = Caps . L.foldr (.|.) 0 . L.map (unCaps . capMask)

fromCaps :: Caps -> [Extension]
fromCaps caps = L.filter (allowed caps) [minBound..maxBound]

{-----------------------------------------------------------------------
    Handshake
-----------------------------------------------------------------------}

-- | Handshake message is used to exchange all information necessary
-- to establish connection between peers.
--
data Handshake = Handshake {
    -- | Identifier of the protocol. This is usually equal to defaultProtocol
    hsProtocol    :: BS.ByteString

    -- | Reserved bytes used to specify supported BEP's.
  , hsReserved    :: Caps

    -- | Info hash of the info part of the metainfo file. that is
    -- transmitted in tracker requests. Info hash of the initiator
    -- handshake and response handshake should match, otherwise
    -- initiator should break the connection.
    --
  , hsInfoHash    :: InfoHash

    -- | Peer id of the initiator. This is usually the same peer id
    -- that is transmitted in tracker requests.
    --
  , hsPeerId      :: PeerId

  } deriving (Show, Eq)

instance Serialize Handshake where
  put Handshake {..} = do
    S.putWord8 (fromIntegral (BS.length hsProtocol))
    S.putByteString hsProtocol
    S.put hsReserved
    S.put hsInfoHash
    S.put hsPeerId

  get = do
    len  <- S.getWord8
    Handshake <$> S.getBytes (fromIntegral len)
              <*> S.get
              <*> S.get
              <*> S.get

instance Pretty Handshake where
  pretty Handshake {..}
    = text (BC.unpack hsProtocol) <+> pretty (fingerprint hsPeerId)

-- | Get handshake message size in bytes from the length of protocol
-- string.
handshakeSize :: Word8 -> Int
handshakeSize n = 1 + fromIntegral n + 8 + 20 + 20

-- | Maximum size of handshake message in bytes.
handshakeMaxSize :: Int
handshakeMaxSize = handshakeSize maxBound

-- | Default protocol string "BitTorrent protocol" as is.
defaultBTProtocol :: BS.ByteString
defaultBTProtocol = "BitTorrent protocol"

-- | Length of info hash and peer id is unchecked, so it /should/ be
-- equal 20.
defaultHandshake :: InfoHash -> PeerId -> Handshake
defaultHandshake = Handshake defaultBTProtocol def

{-----------------------------------------------------------------------
    Regular messages
-----------------------------------------------------------------------}

class PeerMessage a where
  envelop :: ExtendedCaps -> a -> Message

data StatusUpdate
  = Choke
  | Unchoke
  | Interested
  | NotInterested
    deriving (Show, Eq, Ord, Enum, Bounded)

instance Pretty StatusUpdate where
  pretty = text . show

instance PeerMessage StatusUpdate where
  envelop _ = Status

data RegularMessage =
    -- | Zero-based index of a piece that has just been successfully
    -- downloaded and verified via the hash.
    Have    ! PieceIx

    -- | The bitfield message may only be sent immediately after the
    -- handshaking sequence is complete, and before any other message
    -- are sent. If client have no pieces then bitfield need not to be
    -- sent.
  | Bitfield !Bitfield

    -- | Request for a particular block. If a client is requested a
    -- block that another peer do not have the peer might not answer
    -- at all.
  | Request ! BlockIx

    -- | Response to a request for a block.
  | Piece   !(Block BL.ByteString)

    -- | Used to cancel block requests. It is typically used during
    -- "End Game".
  | Cancel  !BlockIx
    deriving (Show, Eq)

-- TODO
-- data Availability = Have | Bitfield
-- data Transfer
--   = Request !BlockIx
--   | Piece   !(Block BL.ByteString)
--   | Cancel  !BlockIx


instance Pretty RegularMessage where
  pretty (Have     ix ) = "Have"     <+> int ix
  pretty (Bitfield _  ) = "Bitfield"
  pretty (Request  ix ) = "Request"  <+> pretty ix
  pretty (Piece    blk) = "Piece"    <+> pretty blk
  pretty (Cancel   i  ) = "Cancel"   <+> pretty i

instance PeerMessage RegularMessage where
  envelop _ = Regular

instance PeerMessage Bitfield where
  envelop c = envelop c . Bitfield

instance PeerMessage BlockIx where
  envelop c = envelop c . Request

instance PeerMessage (Block BL.ByteString) where
  envelop c = envelop c . Piece

-- | BEP6 messages.
data FastMessage =
    -- | If a peer have all pieces it might send the 'HaveAll' message
    -- instead of 'Bitfield' message. Used to save bandwidth.
    HaveAll

    -- | If a peer have no pieces it might send 'HaveNone' message
    -- intead of 'Bitfield' message. Used to save bandwidth.
  | HaveNone

    -- | This is an advisory message meaning "you might like to
    -- download this piece." Used to avoid excessive disk seeks and
    -- amount of IO.
  | SuggestPiece  !PieceIx

    -- | Notifies a requesting peer that its request will not be satisfied.
  | RejectRequest !BlockIx

    -- | This is an advisory messsage meaning "if you ask for this
    -- piece, I'll give it to you even if you're choked." Used to
    -- shorten starting phase.
  | AllowedFast   !PieceIx
    deriving (Show, Eq)

instance Pretty FastMessage where
  pretty (HaveAll          ) = "Have all"
  pretty (HaveNone         ) = "Have none"
  pretty (SuggestPiece  pix) = "Suggest"      <+> int    pix
  pretty (RejectRequest bix) = "Reject"       <+> pretty bix
  pretty (AllowedFast   pix) = "Allowed fast" <+> int    pix

instance PeerMessage FastMessage where
  envelop _ = Fast

{-----------------------------------------------------------------------
--  Extended messages
-----------------------------------------------------------------------}

type ExtendedMessageId = Word8
type ExtendedIdMap     = IntMap

data ExtendedExtension
  = ExtMetadata -- ^ BEP 9
    deriving (Show, Eq, Typeable)

instance Pretty ExtendedExtension where
  pretty ExtMetadata = "Extension for Peers to Send Metadata Files"

extId :: ExtendedExtension -> ExtendedMessageId
extId ExtMetadata = 1
{-# INLINE extId #-}

extString :: ExtendedExtension -> BS.ByteString
extString ExtMetadata = "ut_metadata"
{-# INLINE extString #-}

fromS :: BS.ByteString -> ExtendedExtension
fromS "ut_metadata" = ExtMetadata

-- | The extension IDs must be stored for every peer, because every
-- peer may have different IDs for the same extension.
--
newtype ExtendedCaps = ExtendedCaps
  { extendedCaps :: ExtendedIdMap ExtendedExtension
  } deriving (Show, Eq, Monoid)

-- | Empty set.
instance Default ExtendedCaps where
  def = ExtendedCaps IM.empty

instance Pretty ExtendedCaps where
  pretty = ppBEncode . toBEncode

instance BEncode ExtendedCaps where
  toBEncode = BDict . BE.fromAscList . L.sortBy (comparing fst)
            . L.map mkPair . IM.toList . extendedCaps
    where
      mkPair (eid, ex) = (extString ex, toBEncode eid)

  fromBEncode (BDict bd) = ExtendedCaps <$> undefined

  fromBEncode _          = decodingError "ExtendedCaps"


-- | This message should be sent immediately after the standard
-- bittorrent handshake to any peer that supports this extension
-- protocol. Extended handshakes can be sent more than once, however
-- an implementation may choose to ignore subsequent handshake
-- messages.
--
data ExtendedHandshake = ExtendedHandshake
  { -- | If this peer has an IPv4 interface, this is the compact
    -- representation of that address.
    ehsIPv4        :: Maybe HostAddress

    -- | If this peer has an IPv6 interface, this is the compact
    -- representation of that address.
  , ehsIPv6        :: Maybe HostAddress6

    -- | Dictionary of supported extension messages which maps names
    -- of extensions to an extended message ID for each extension
    -- message.
  , ehsCaps        :: ExtendedCaps

    -- | Local TCP /listen/ port. Allows each side to learn about the
    -- TCP port number of the other side.
  , ehsPort        :: Maybe PortNumber

    -- | Request queue the number of outstanding 'Request' messages
    -- this client supports without dropping any.
  , ehsQueueLength :: Maybe Int

    -- | Client name and version.
  , ehsVersion     :: Maybe Text

--    -- |
--  , yourip  :: Maybe (Either HostAddress HostAddress6)
  } deriving (Show, Eq, Typeable)

instance Default ExtendedHandshake where
  def = ExtendedHandshake Nothing Nothing def Nothing Nothing Nothing

instance BEncode ExtendedHandshake where
  toBEncode ExtendedHandshake {..} = toDict $
       "ipv4"   .=? ehsIPv4 -- FIXME invalid encoding
    .: "ipv6"   .=? ehsIPv6 -- FIXME invalid encoding
    .: "m"      .=! ehsCaps
    .: "p"      .=? ehsPort
    .: "reqq"   .=? ehsQueueLength
    .: "v"      .=? ehsVersion
--    .: "yourip" .=? yourip
    .: endDict

  fromBEncode = fromDict $ ExtendedHandshake
    <$>? "ipv4"
    <*>? "ipv6"
    <*>! "m"
    <*>? "p"
    <*>? "reqq"
    <*>? "v"
--    <*>? "yourip"

instance Pretty ExtendedHandshake where
  pretty = PP.text . show

instance PeerMessage ExtendedHandshake where
  envelop c = envelop c . EHandshake

{-----------------------------------------------------------------------
-- Metadata exchange
-----------------------------------------------------------------------}

type MetadataId = Int

pieceSize :: Int
pieceSize = 16 * 1024

data ExtendedMetadata
  = MetadataRequest PieceIx
  | MetadataData    PieceIx Int
  | MetadataReject  PieceIx
  | MetadataUnknown BValue
    deriving (Show, Eq, Typeable)

instance BEncode ExtendedMetadata where
  toBEncode (MetadataRequest pix) = toDict $
       "msg_type"   .=! (0 :: MetadataId)
    .: "piece"      .=! pix
    .: endDict
  toBEncode (MetadataData    pix totalSize) = toDict $
       "msg_type"   .=! (1 :: MetadataId)
    .: "piece"      .=! pix
    .: "total_size" .=! totalSize
    .: endDict
  toBEncode (MetadataReject  pix)  = toDict $
       "msg_type"   .=! (2 :: MetadataId)
    .: "piece"      .=! pix
    .: endDict
  toBEncode (MetadataUnknown bval) = bval

  fromBEncode = undefined

instance Pretty ExtendedMetadata where
  pretty (MetadataRequest pix  ) = "Request" <+> PP.int pix
  pretty (MetadataData    pix s) = "Data"    <+> PP.int pix <+> PP.int s
  pretty (MetadataReject  pix  ) = "Reject"  <+> PP.int pix
  pretty (MetadataUnknown bval ) = ppBEncode bval

instance PeerMessage ExtendedMetadata where
  envelop c = envelop c . EMetadata

-- | For more info see <http://www.bittorrent.org/beps/bep_0010.html>
data ExtendedMessage
  = EHandshake ExtendedHandshake
  | EMetadata  ExtendedMetadata
  | EUnknown   ExtendedMessageId BS.ByteString
    deriving (Show, Eq, Typeable)

instance Pretty ExtendedMessage where
  pretty (EHandshake ehs) = pretty ehs
  pretty (EMetadata  msg) = pretty msg
  pretty (EUnknown mid _) = "Unknown" <+> PP.text (show mid)

instance PeerMessage ExtendedMessage where
  envelop _ = Extended

{-----------------------------------------------------------------------
-- The message datatype
-----------------------------------------------------------------------}

type MessageId = Word8

-- | Messages used in communication between peers.
--
--   Note: If some extensions are disabled (not present in extension
--   mask) and client receive message used by the disabled
--   extension then the client MUST close the connection.
--
data Message
    -- core
  = KeepAlive
  | Status   !StatusUpdate
  | Regular  !RegularMessage

    -- extensions
  | Port     !PortNumber
  | Fast     !FastMessage
  | Extended !ExtendedMessage
    deriving (Show, Eq)

instance Default Message where
  def = KeepAlive
  {-# INLINE def #-}

-- | Payload bytes are omitted.
instance Pretty Message where
  pretty (KeepAlive  ) = "Keep alive"
  pretty (Status    m) = pretty m
  pretty (Regular   m) = pretty m
  pretty (Port      p) = "Port" <+> int (fromEnum p)
  pretty (Fast      m) = pretty m
  pretty (Extended  m) = pretty m

instance PeerMessage Message where
  envelop _ = id

instance PeerMessage PortNumber where
  envelop _ = Port

-- | Can be used to check if this message is allowed to send\/recv in
--  current session.
requires :: Message -> Maybe Extension
requires  KeepAlive   = Nothing
requires (Status   _) = Nothing
requires (Regular  _) = Nothing
requires (Port     _) = Just ExtDHT
requires (Fast     _) = Just ExtFast
requires (Extended _) = Just ExtExtended

getInt :: S.Get Int
getInt = fromIntegral <$> S.getWord32be
{-# INLINE getInt #-}

putInt :: S.Putter Int
putInt = S.putWord32be . fromIntegral
{-# INLINE putInt #-}

instance Serialize Message where
  get = do
    len <- getInt
    if len == 0 then return KeepAlive
      else do
        mid <- S.getWord8
        case mid of
          0x00 -> return $ Status Choke
          0x01 -> return $ Status Unchoke
          0x02 -> return $ Status Interested
          0x03 -> return $ Status NotInterested
          0x04 -> (Regular . Have)    <$> getInt
          0x05 -> (Regular . Bitfield . fromBitmap)
                                      <$> S.getByteString (pred len)
          0x06 -> (Regular . Request) <$> S.get
          0x07 -> (Regular . Piece)   <$> getBlock (len - 9)
          0x08 -> (Regular . Cancel)  <$> S.get
          0x09 -> Port <$> S.get
          0x0D -> (Fast . SuggestPiece) <$> getInt
          0x0E -> return $ Fast HaveAll
          0x0F -> return $ Fast HaveNone
          0x10 -> (Fast . RejectRequest) <$> S.get
          0x11 -> (Fast . AllowedFast)   <$> getInt
          0x14 -> Extended <$> getExtendedMessage (pred len)
          _    -> do
            rm <- S.remaining >>= S.getBytes
            fail $ "unknown message ID: " ++ show mid ++ "\n"
                ++ "remaining available bytes: " ++ show rm

    where
      getBlock :: Int -> S.Get (Block BL.ByteString)
      getBlock len = Block <$> getInt <*> getInt
                           <*> S.getLazyByteString (fromIntegral len)
      {-# INLINE getBlock #-}

  put  KeepAlive    = putInt 0
  put (Status  msg) = putStatus  msg
  put (Regular msg) = putRegular msg
  put (Port    p  ) = putPort    p
  put (Fast    msg) = putFast    msg
  put (Extended m ) = putExtendedMessage m

putStatus :: Putter StatusUpdate
putStatus su = putInt 1  >> S.putWord8 (fromIntegral (fromEnum su))

putRegular :: Putter RegularMessage
putRegular (Have i)      = putInt 5  >> S.putWord8 0x04 >> putInt i
putRegular (Bitfield bf) = putInt l  >> S.putWord8 0x05 >> S.putLazyByteString b
  where b = toBitmap bf
        l = succ (fromIntegral (BL.length b))
        {-# INLINE l #-}
putRegular (Request blk) = putInt 13 >> S.putWord8 0x06 >> S.put blk
putRegular (Piece   blk) = putInt l  >> S.putWord8 0x07 >> putBlock
  where l = 9 + fromIntegral (BL.length (blkData blk))
        {-# INLINE l #-}
        putBlock = do putInt (blkPiece blk)
                      putInt (blkOffset  blk)
                      S.putLazyByteString (blkData blk)
        {-# INLINE putBlock #-}
putRegular (Cancel  blk)      = putInt 13 >> S.putWord8 0x08 >> S.put blk

putPort :: Putter PortNumber
putPort p = putInt 3  >> S.putWord8 0x09 >> S.put p

putFast :: Putter FastMessage
putFast  HaveAll           = putInt 1  >> S.putWord8 0x0E
putFast  HaveNone          = putInt 1  >> S.putWord8 0x0F
putFast (SuggestPiece pix) = putInt 5  >> S.putWord8 0x0D >> putInt pix
putFast (RejectRequest i ) = putInt 13 >> S.putWord8 0x10 >> S.put i
putFast (AllowedFast   i ) = putInt 5  >> S.putWord8 0x11 >> putInt i

getExtendedHandshake :: Int -> S.Get ExtendedHandshake
getExtendedHandshake messageSize = do
  bs <- getByteString messageSize
  either fail pure $ BE.decode bs

getExtendedMessage :: Int -> S.Get ExtendedMessage
getExtendedMessage messageSize = do
  msgId   <- getWord8
  let msgBodySize = messageSize - 1
  case msgId of
    0 -> EHandshake     <$> getExtendedHandshake msgBodySize
    1 -> EMetadata      <$> undefined
    _ -> EUnknown msgId <$> getByteString        msgBodySize

extendedMessageId :: MessageId
extendedMessageId = 20

-- NOTE: in contrast to getExtendedMessage this function put length
-- and message id too!
putExtendedMessage :: ExtendedMessage -> S.Put
putExtendedMessage (EHandshake hs) = do
  putExtendedMessage $ EUnknown 0 $ BL.toStrict $ BE.encode hs
putExtendedMessage (EMetadata msg)  = do
  putExtendedMessage $ EUnknown (extId ExtMetadata)
    $ BL.toStrict $ BE.encode msg
putExtendedMessage (EUnknown mid  bs) = do
  putWord32be $ fromIntegral (4 + 1 + BS.length bs)
  putWord8 extendedMessageId
  putWord8 mid
  putByteString bs
