module Flow.Source
  ( Source

  , empty

  , read
  , getSequenceNo
  , setSequenceNo
  , isWritable
  , flush

  , writable
  , forward
  , merge

  , write
  , writeForce
  , writeBatch
  , writeBatchForce
  , writeSeq
  , writeSeqForce
  , writeBatchSeq
  , writeBatchSeqForce
  ) where

{-| # Source

This represents a source of deltas. Everything is lazily computed so if you don't reach read in
a given computation cycle, no work will be performed. In addition, no matter how many reads you
do, the result will only be computed once, because the underlying implementation is lazy by
memoization (see [maxsnew/lazy](https://github.com/maxsnew/lazy)).

# Source Type
@docs Source

# New Source
@docs empty

# Read and Flush
@docs read, getSequenceNo, setSequenceNo, isWritable, flush

# Routing
@docs writable, forward, merge

# Low Level Writes
@docs write, writeForce, writeBatch, writeBatchForce, writeSeq, writeSeqForce, writeBatchSeq, writeBatchSeqForce

-}

import Dict exposing (Dict)

import Flow.Transform exposing (Transform)
import Lazy exposing (Lazy)


type alias SourceStruct a =
  { sequenceNo : Int
  , writeSet : Lazy (Dict String (Int, Maybe a))
  , output : Lazy (List ((String, Int), Maybe a))
  , writable : Bool
  }


emptySourceStruct : SourceStruct a
emptySourceStruct =
  { sequenceNo = 0
  , writeSet = emptyWriteSet_
  , output = emptyOutput_
  , writable = True
  }


{-| A source object. -}
type Source a =
  Source (SourceStruct a)


{-| A new source. -}
empty : Source a
empty =
  Source emptySourceStruct


{-| Read the current date source stream buffer. -}
read : Source a -> List ((String, Int), Maybe a)
read (Source source) =
  Lazy.force source.output


{-| Get the current sequence number from the source. -}
getSequenceNo : Source a -> Int
getSequenceNo (Source source) =
  source.sequenceNo


{-| Set the source sequence number. This should not be done unless you are absolutely sure of what
you are doing. -}
setSequenceNo : Int -> Source a -> Source a
setSequenceNo seqno (Source source as sourceShell) =
  if seqno /= source.sequenceNo then
    Source { source | sequenceNo = seqno }
  else
    sourceShell


{-| Check to see if this is a writable source. -}
isWritable : Source a -> Bool
isWritable (Source source) =
  source.writable


{-| Make a writable source. -}
writable : Source a -> Source a
writable (Source source as sourceShell) =
  if source.writable then
    sourceShell
  else
    writeBatchSeq' source.output (sourceEmptyWriteSet_ source)
    |> Source


{-| Transform a source. -}
forward
  :  Transform a b
  -> Source a
  -> Source b
forward xform (Source source as sourceShell) =
  Source
    { output =
        source.output
          `Lazy.andThen` \list -> Flow.Transform.apply xform list
    , sequenceNo = source.sequenceNo
    , writeSet = emptyWriteSet_
    , writable = False
    }


{-| Merge a list of sources -}
merge : List (Source doc) -> Source doc
merge sources =
  List.foldl
    (\(Source source) mergedSource ->
      { mergedSource
      | sequenceNo = max (source.sequenceNo + 1) mergedSource.sequenceNo
      }
      |> writeBatchSeq' source.output
    ) emptySourceStruct sources
  |> Source


{-| Flush the source stream buffer, replacing it with an empty list. -}
flush : Source a -> Source a
flush (Source source) =
  Source (sourceEmptyWriteSet_ source)


{-| Write a document or void with a given reference. This monotonically increases the sequence
number. -}
write : String -> Maybe a -> Source a -> Source a
write ref mDocument =
  writeBatch [ (ref, mDocument) ]


{-| Write a document or void with a given reference. This monotonically increases the sequence
number. If this is not a writable source, we make it writable. -}
writeForce : String -> Maybe a -> Source a -> Source a
writeForce ref mDocument =
  writeBatchForce [ (ref, mDocument) ]


{-| Write a list of (reference, Maybe document) pairs, monotonically increasing the sequence number for
each write. -}
writeBatch : List (String, Maybe a) -> Source a -> Source a
writeBatch =
  writeBatch' False


{-| Write a list of (reference, Maybe document) pairs, monotonically increasing the sequence number for
each write. If this is not a writable source, we make it writable. -}
writeBatchForce : List (String, Maybe a) -> Source a -> Source a
writeBatchForce =
  writeBatch' True


writeBatch' : Bool -> List (String, Maybe a) -> Source a -> Source a
writeBatch' bForce writels (Source source as sourceShell) =
  if source.writable then
    let
      (newSequenceNo, writes) =
        List.foldl
          (\(ref, mDoc) (seqno', writes') -> (seqno' + 1, ((ref, seqno'), mDoc) :: writes'))
          (source.sequenceNo, [])
          writels
    in
      { source | sequenceNo = newSequenceNo }
      |> writeBatchSeq' (Lazy.lazy (\() -> writes))
      |> Source
  else if bForce then
    writable sourceShell
    |> writeBatch' True writels
  else
    sourceShell


{-| Write a ((reference, sequenceNumber), Maybe document) pair, such that the output is only updated
if sequence number from the input pair is greater than the sequence number of the current latest
input pair for the given key. -}
writeSeq : (String, Int) -> Maybe a -> Source a -> Source a
writeSeq refPair mDocument =
  writeBatchSeq [ (refPair, mDocument) ]


{-| Write a ((reference, sequenceNumber), Maybe document) pair, such that the output is only updated
if sequence number from the input pair is greater than the sequence number of the current latest
input pair for the given key. If this is not a writable source, we make it writable.-}
writeSeqForce : (String, Int) -> Maybe a -> Source a -> Source a
writeSeqForce refPair mDocument =
  writeBatchSeqForce [ (refPair, mDocument) ]


{-| Write a list of ((reference, sequenceNumber), Maybe document) pairs, such that the output is
only updated if sequence number from each input pair is greater than the sequence number of the
current latest input pair for the the corresponding key. -}
writeBatchSeq : List ((String, Int), Maybe a) -> Source a -> Source a
writeBatchSeq =
  writeBatchSeqImpl False


{-| Write a list of ((reference, sequenceNumber), Maybe document) pairs, such that the output is
only updated if sequence number from each input pair is greater than the sequence number of the
current latest input pair for the the corresponding key. If this is not a writable source, we make
it writable. -}
writeBatchSeqForce : List ((String, Int), Maybe a) -> Source a -> Source a
writeBatchSeqForce =
  writeBatchSeqImpl True


writeBatchSeqImpl : Bool -> List ((String, Int), Maybe a) -> Source a -> Source a
writeBatchSeqImpl bForce seqls (Source source as sourceShell) =
  if source.writable then
    writeBatchSeq' (Lazy.lazy (\() -> seqls)) source
    |> Source
  else if bForce then
    writable sourceShell
    |> writeBatchSeqImpl True seqls
  else
    sourceShell


writeBatchSeq' : Lazy (List ((String, Int), Maybe a)) -> SourceStruct a -> SourceStruct a
writeBatchSeq' seqlsl source =
  if source.writable then
    let
      newWriteSet =
        Lazy.map2
          (List.foldl
            (\((ref, seqno), json) -> Dict.update ref
              (\existing -> Just (seqno, json)
                |> \replacement -> existing
                |> Maybe.map (\(seqno', value) -> if seqno' >= seqno then existing else replacement)
                |> Maybe.withDefault replacement
              )
            )
          ) source.writeSet seqlsl
    in
      { source | writeSet = newWriteSet }
      |> stageLazyOutput_
  else
    source



stageLazyOutput_ : SourceStruct a -> SourceStruct a
stageLazyOutput_ source =
  { source
  | output = source.writeSet
      `Lazy.andThen` \writeSet ->
        Lazy.lazy
          (\() -> Dict.foldr
            (\ref (seqno, json) ->
              (::) ((ref, seqno), json)
            ) [] writeSet
          )
  }


sourceEmptyWriteSet_ : SourceStruct a -> SourceStruct a
sourceEmptyWriteSet_ source =
  { emptySourceStruct
  | sequenceNo = source.sequenceNo
  }


emptyWriteSet_ : Lazy (Dict String (Int, Maybe a))
emptyWriteSet_ =
  Lazy.lazy (\() -> Dict.empty)


emptyOutput_ : Lazy (List ((String, Int), Maybe a))
emptyOutput_ =
  Lazy.lazy (\() -> [])
