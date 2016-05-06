module Flow.Internal.Stream
  ( Factory
  , Pipe
  , Emitter

  , factory
  , flush
  , write
  , writeBatch
  , emit

  , stub
  , inlet
  , transform
  , capture
  , tap
  , combine

  , output
  , getResynch
  ) where

{-| # Stream

This represents a source of deltas. Everything is lazily computed so if you don't reach read in
a given computation cycle, no work will be performed. In addition, no matter how many reads you
do, the result will only be computed once, because the underlying implementation is lazy by
memoization (see [maxsnew/lazy](https://github.com/maxsnew/lazy)).

# Types
@docs Factory, Pipe, Emitter

# Write
@docs factory, flush, write, writeBatch, emit

# Dataflow
@docs stub, inlet, transform, capture, tap, combine

# Read
@docs output, getResynch

-}

import Dict exposing (Dict)

import Trampoline exposing (..)

import Flow.Internal.Transform as Internal exposing (Transform)
import Flow.Sequence as Sequence exposing (Counter)


import Lazy.List as LazyList exposing (LazyList, LazyListView, (+++), (:::))
import Lazy exposing (Lazy)

import Signal exposing (Address)
import Task exposing (Task)
import Time

import Json.Decode


type Event a =
  EventDelta (Int, Delta a)
  | EventSynch


type alias Snapshot a =
  Lazy (Dict String (Int, a))


type alias DeltaRecord a =
  { writeSet : Lazy (Dict String (Int, Delta a))
  , deltas : LazyList (Int, Delta a)
  , empty' : Bool
  }

lazyEmptyDict =
  Lazy.lazy (\() -> Dict.empty)


type Delta a =
  Add String a
  | Remove String a
  | Modify String (a, a)
  | RefError String Json.Decode.Value


type Payload a =
  Changed (DeltaRecord a)              -- change
  | Synch (Snapshot a) (DeltaRecord a) -- Applied from empty state


deltaRef : Delta a -> String
deltaRef delta =
  case delta of
    Add ref _ -> ref
    Remove ref _ -> ref
    Modify ref _ -> ref
    RefError ref _ -> ref


payloadSnapshot : Payload a -> Maybe (Snapshot a)
payloadSnapshot payload =
  case payload of
    Changed _ -> Nothing
    Synch snapshot _ -> Just snapshot


payloadDeltaRecord : Payload a -> DeltaRecord a
payloadDeltaRecord payload =
  case payload of
    Changed record -> record
    Synch _ record -> record


payloadClearTarget : Payload a -> Bool
payloadClearTarget payload =
  case payload of
    Change _ -> False
    Synch _ _ -> True


payloadWriteRecord : Payload a -> DeltaRecord a
payloadWriteRecord payload =
  case payload of
    Changed record -> record
    Synch snapshot record -> updateDeltaRecord record (snapshotDeltaRecord snapshot)


emptyDeltaRecord : DeltaRecord a
emptyDeltaRecord =
  { writeSet = lazyEmptyDict
  , deltas = LazyList.empty
  , empty' = True
  }


isDeltaRecordEmpty : DeltaRecord a -> Bool
isDeltaRecordEmpty = .empty'


snapshotDeltaRecord : Maybe (Snapshot a) -> DeltaRecord a
snapshotDeltaRecord mSnapshot =
  case mSnapshot of
    Just snapshot ->
      let
        snapshotDict = Lazy.force snapshot

      in
        if Dict.isEmpty snapshotDict then
          emptyDeltaRecord
        else
          let
            writeSet' =
              Lazy.lazy (\() -> Dict.map (\ref (seqn, data) -> (seqn, Add ref data) snapshotDict)

          in
            { writeSet = writeSet'
            , deltas = Lazy.map Dict.values writeSet'
            , empty = False
            }
    Nothing ->
      emptyDeltaRecord


writeDeltaRecord : (Int, Delta a) -> DeltaRecord a -> DeltaRecord a
writeDeltaRecord ((seqn, delta) as pair) deltaRecord =
  let
    ref = deltaRef delta

    outputs =
      Lazy.map2
        (\writeSet deltasView ->
          Dict.get ref writeSet
          |> updateDelta' pair
          |> Maybe.map
            (\((seqn', delta') as pair') ->
              ( Dict.insert ref pair' writeSet
              -- Modified from the LazyList implementation.
              , case deltasView of
                  LazyList.Nil -> LazyList.Cons pair' LazyList.empty
                  LazyList.Cons first rest ->
                    Lazy.force (first ::: rest +++ LazyList.singleton pair')
              )
            )
          |> Maybe.withDefault (writeSet, deltasView)
        ) deltaRecord.writeSet deltaRecord.deltas

  in
    -- These will be recomputed simultaneously
    { writeSet = Lazy.map fst outputs
    , deltas = Lazy.map snd outputs
    , empty' = False
    }


updateDeltaRecord : DeltaRecord a -> DeltaRecord a -> DeltaRecord a
updateDeltaRecord updateRecord deltaRecord =
  if deltaRecord.empty' then
    updateRecord
  else if updateRecord.empty' then
    deltaRecord
  else
    foldDeltaRecord' writeDeltaRecord (Lazy.lazy (\() -> deltaRecord)) updateRecord
    |> \deltaRecord' ->
      { writeSet = Lazy.map .writeSet deltaRecord'
      , deltas = Lazy.map .deltas deltaRecord'
      , empty' = False
      }


foldDeltaRecord : ((Int, Delta a) -> b -> b) -> b -> DeltaRecord a -> b
foldDeltaRecord f out deltaRecord =
  LazyList.foldl f out deltaRecord.deltas


foldDeltaRecord' : ((Int, Delta a) -> b -> b) -> Lazy b -> DeltaRecord a -> Lazy b
foldDeltaRecord' f out deltaRecord =
  Lazy.map (flip (foldDeltaRecord f) deltaRecord) out


sendDeltaRecord : Float -> Address (Event a) -> DeltaRecord a -> Maybe (Task never ())
sendDeltaRecord rate address deltaRecord =
  if deltaRecord.empty' then
    Nothing
  else
    let
      rateMs =
        rate * Time.millisecond

      lazyTask =
        foldDeltaRecord'
          (if rateMs > 0.1 then
            (\pair task' -> task'
              `Task.andThen` \_ -> Task.sleep rateMs
              `Task.andThen` \_ -> Signal.send address (EventDelta pair))
          else
            (\pair task' -> task' `Task.andThen` \_ -> Signal.send address (EventDelta pair))
          )
          (Lazy.lazy (\() -> Task.succeed ()))
          deltaRecord
    in
      -- do all sending asynchronously.
      -- send the delta list strictly in sequence.
      Just (Task.succeed () `Task.andThen` \_ -> Lazy.force lazyTask)


emptyPayload : Payload a
emptyPayload =
  Changed emptyDeltaRecord


isPayloadEmpty : Payload a -> Bool
isPayloadEmpty payload =
  case payload of
    Changed r -> isDeltaRecordEmpty r
    Synch s r -> isDeltaRecordEmpty r && Dict.isEmpty (Lazy.force s)


synchPayload : Dict String (Int, a) -> Payload a
synchPayload snap =
  Synch (Lazy.lazy (\() -> snap)) emptyDeltaRecord


updatePayload : DeltaRecord a -> Payload a -> Payload a
updatePayload updateRecord payload =
  case payload of
    Synch snap deltas -> Synch snap (updateDeltaRecord updateRecord deltas)
    Changed deltas -> Changed (updateDeltaRecord updateRecord deltas)


sendPayload : Float -> Address (Event a) -> Payload a -> Maybe (Task never ())
sendPayload rate address payload =
  if isPayloadEmpty payload then
    Nothing
  else
    let
      bClear = payloadClearTarget payload
      writeTask =
        Lazy.lazy
          (\() -> payloadWriteRecord payload
          |> sendDeltaRecord rate address
          |> Maybe.withDefault (Task.succeed ()))

      firstTask =
        if bClear then
          Signal.send address EventSynch
        else
          Task.succeed ()
    in
      Just (firstTask `Task.andThen` \_ -> Lazy.force writeTask)



updateDelta' : (Int, Delta a) -> Maybe (Int, Delta a) -> Maybe (Int, Delta a)
updateDelta' ((seqno, delta) as pair) priorDelta =
  case priorDelta of
    Just (priorSeqno, _) ->
      if priorSeqno < seqno then Just pair else Nothing

    _ ->
      Just pair

{-
type alias PipeStruct a =
  { source : Lazy (Stream a)
  , resynch : Bool
  }


{-| A factory is used to write documents in to a source stream. -}
type Factory a =
  Factory (PipeStruct a)


{-| Pipes can be transformed and combined. Pipes are a transient representation of dataflow
configuration, and do not do any work themselves. -}
type Pipe a =
  Pipe (PipeStruct a)

{-| An emitter can be obtained from a Factory or a Pipe, and can be queried for the actual
resulting output of it's source object. Querying an emitter will result in the lazy evaluation of
all pipes that contribute to an emitter. -}
type Emitter a =
  Emitter (PipeStruct a)

--
-- SOURCE FACTORY
--

{-| A new source factory. This will start with a sequence number of 0. -}
factory : Factory a
factory =
  Factory { source = emptyLazy_, resynch = False }


{-| Emit a resynchronization flag from a factory. -}
resynch : Factory a -> Factory a
resynch (Factory struct) =
  Factory { struct | resynch = True }


{-| Flush a source factory. This will remove any writes, but keep the current write sequence
number. -}
flush : Factory a -> Factory a
flush (Factory {source}) =
  Factory { resynch = False, source = Lazy.map flushSource' source }


{-| Write a reference document pair to a factory, increasing the sequence number monotonically. -}
write : String -> Delta a -> (Counter, Factory a) -> (Counter, Factory a)
write ref mDoc (counter, Factory struct) =
  let
    (newCounter, newSource) =
      write' ref mDoc (counter, struct.source)
  in
    ( newCounter
    , Factory { struct | source = newSource }
    )


{-| Write a collection of reference document pairs to a factory, increasing the sequence number
monotonically for each. -}
writeBatch : List (String, Delta a) -> (Counter, Factory a) -> (Counter, Factory a)
writeBatch mBatch (counter, Factory struct) =
  let
    (newCounter, newSource) =
      writeBatch' mBatch (counter, struct.source)

  in
    ( newCounter
    , Factory { struct | source = newSource }
    )


{-| Create an emitter from a factory. An emitter can be turned in to it's output, thus computing
it's final result lazily under the hood, or it can be `capture`d in to a pipe. This is useful if
you want to tap intermediate results. -}
emit : Factory a -> Emitter a
emit (Factory struct) =
  Emitter struct


--
-- SOURCE PIPE
--


{-| Create a stub pipe with no documents. -}
stub : Pipe a
stub =
  Pipe { source = emptyLazy_, resynch = False }


{-| Create a pipe directly from a factory. This is equivalent to:

    emit >> capture

-}
inlet : Factory a -> Pipe a
inlet = emit >> capture


{-| Apply a transformation over the individual documents in the pipe. This transforms the type of
the pipe and may filter some documents out. -}
transform : Transform a b -> Pipe a -> Pipe b
transform xform (Pipe struct) =
  Pipe { source = Lazy.map (filterSource' xform) struct.source, resynch = struct.resynch }


{-| Capture an emitter as a pipe. -}
capture : Emitter a -> Pipe a
capture (Emitter struct) =
  Pipe struct


{-| Tap a pipe as an emitter to extract output. -}
tap : Pipe a -> Emitter a
tap (Pipe struct) =
  Emitter struct


{-| Combine a list of pipes producing an aggregate output. -}
combine : List (Pipe a) -> Pipe a
combine sources =
  let
    headSource = List.head sources
    sourcesTail = List.tail sources |> Maybe.withDefault []
  in
    case (headSource, sourcesTail) of
      (Nothing, []) -> stub
      (Just p', []) -> p'
      (Just _, _) ->
        let
          doResynch ls =
            case ls of
              [] -> Done False
              (Pipe {resynch}) :: ls' ->
                if resynch then
                  Done True
                else
                  Continue (\() -> doResynch ls')

          newSource =
            Lazy.lazy
              (\() ->
                List.foldl
                  (\(Pipe s) sourceStruct ->
                    writeBatchSeq'' (Lazy.force s.source |> readLazySource') sourceStruct
                  )
                  emptySourceStruct
                  sources
                |> Stream
              )
        in
          Pipe
            { source = newSource
            , resynch = trampoline (doResynch sources)
            }

      (_, _) ->
        Debug.crash "Unreachable."

--
-- SOURCE EMITTER
--

{-| Get the output for a given emitter. This forces computation of the entire set dependencies for
this emitter.  -}
output : Emitter a -> List ((String, Int), Delta a)
output (Emitter {source}) =
  Lazy.force source
  |> readSource'


{-| Check to see if the resynch flag is set on this emitter. -}
getResynch : Emitter a -> Bool
getResynch (Emitter {resynch}) =
  resynch

--
-- INTERNAL
--


{-| A new source. -}
empty : Stream a
empty =
  Stream emptySourceStruct


{-| Read the current date source stream buffer. -}
readSource' : Stream a -> List ((String, Int), Delta a)
readSource' (Stream source) =
  Lazy.force source.output


readLazySource' : Stream a -> Lazy (List ((String, Int), Delta a))
readLazySource' (Stream source) =
  source.output


{-| Transform a source. -}
filterSource'
  :  Transform a b
  -> Stream a
  -> Stream b
filterSource' xform (Stream source as sourceShell) =
  let
    filterOutput =
      source.output
        `Lazy.andThen` \list -> Internal.apply xform list
  in
    Stream
      { output = filterOutput
      , writeSet = writeSetApply filterOutput emptyWriteSet_
      }


{-| Merge a list of sources -}
merge : List (Stream doc) -> Stream doc
merge sources =
  List.foldl
    (\(Stream source) mergedSource ->
      writeBatchSeq'' source.output mergedSource
    ) emptySourceStruct sources
  |> Stream


{-| Flush the source stream buffer, replacing it with an empty list. -}
flushSource' : Stream a -> Stream a
flushSource' (Stream source) =
  Stream (sourceEmptyWriteSet_ source)



-- LOW LEVEL WRITES

{-| Write a document or void with a given reference. This monotonically increases the sequence
number. -}
write' : String -> Delta a -> (Counter, Lazy (Stream a)) -> (Counter, Lazy (Stream a))
write' ref mDocument =
  writeBatch' [ (ref, mDocument) ]


writeBatch' : List (String, Delta a) -> (Counter, Lazy (Stream a)) -> (Counter, Lazy (Stream a))
writeBatch' writels (counter, lazySource) =
  let
    (newCounter, writes) =
      List.foldl
        (\(ref, mDoc) (ctr, writes') ->
          ( Sequence.step ctr
          , ((ref, Sequence.value ctr), mDoc) :: writes'
          )
        ) (counter, []) writels
  in
    ( newCounter
    , Lazy.map (writeBatchSeq' writes) lazySource
    )


{-| Write a ((reference, sequenceNumber), Maybe document) pair, such that the output is only updated
if sequence number from the input pair is greater than the sequence number of the current latest
input pair for the given key. -}
writeSeq' : (String, Int) -> Delta a -> Stream a -> Stream a
writeSeq' refPair mDocument =
  writeBatchSeq' [ (refPair, mDocument) ]


{-| Write a list of ((reference, sequenceNumber), Maybe document) pairs, such that the output is
only updated if sequence number from each input pair is greater than the sequence number of the
current latest input pair for the the corresponding key. -}
writeBatchSeq' : List ((String, Int), Delta a) -> Stream a -> Stream a
writeBatchSeq' seqls (Stream source as sourceShell) =
  writeBatchSeq'' (Lazy.lazy (\() -> seqls)) source
  |> Stream


writeSetApply : Lazy (List ((String, Int), Delta a)) -> Lazy (Dict String (Int, Delta a)) -> Lazy (Dict String (Int, Delta a))
writeSetApply seqlsl writeSet =
  Lazy.map2
    (List.foldl
      (\((ref, seqno), json) -> Dict.update ref
        (\existing -> Just (seqno, json)
          |> \replacement -> existing
          |> Maybe.map (\(seqno', value) -> if seqno' >= seqno then existing else replacement)
          |> Maybe.withDefault replacement
        )
      )
    ) writeSet seqlsl


writeBatchSeq'' : Lazy (List ((String, Int), Delta a)) -> SourceStruct a -> SourceStruct a
writeBatchSeq'' seqlsl source =
  { source | writeSet = writeSetApply seqlsl source.writeSet }
  |> stageLazyOutput_



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
  emptySourceStruct


emptyWriteSet_ : Lazy (Dict String (Int, Delta a))
emptyWriteSet_ =
  Lazy.lazy (\() -> Dict.empty)


emptyOutput_ : Lazy (List ((String, Int), Delta a))
emptyOutput_ =
  Lazy.lazy (\() -> [])


emptyLazy_ : Lazy (Stream a)
emptyLazy_ =
  Lazy.lazy (\() -> empty)


emptySourceStruct : SourceStruct a
emptySourceStruct =
  { writeSet = emptyWriteSet_
  , output = emptyOutput_
  }
-}
