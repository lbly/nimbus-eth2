# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os, strutils,
  # Beacon chain internals
  ../../../beacon_chain/spec/[forks, state_transition],
  ../../../beacon_chain/spec/datatypes/phase0,
  # Test utilities
  ../../testutil,
  ../fixtures_utils,
  ../../helpers/debug_state

const SanitySlotsDir = SszTestsDir/const_preset/"phase0"/"sanity"/"slots"/"pyspec_tests"

proc runTest(identifier: string) =
  let
    testDir = SanitySlotsDir / identifier
    num_slots = readLines(testDir / "slots.yaml", 2)[0].parseInt.uint64

  proc `testImpl _ slots _ identifier`() =
    test "Slots - " & identifier:
      var
        preState = newClone(parseTest(testDir/"pre.ssz_snappy", SSZ, phase0.BeaconState))
        fhPreState = (ref ForkedHashedBeaconState)(phase0Data: phase0.HashedBeaconState(
          data: preState[], root: hash_tree_root(preState[])), kind: BeaconStateFork.Phase0)
        cache = StateCache()
        info: ForkedEpochInfo
      let postState = newClone(parseTest(testDir/"post.ssz_snappy", SSZ, phase0.BeaconState))

      check:
        process_slots(
          defaultRuntimeConfig,
          fhPreState[], getStateField(fhPreState[], slot) + num_slots, cache,
          info, {})

        getStateRoot(fhPreState[]) == postState[].hash_tree_root()
      let newPreState = newClone(fhPreState.phase0Data.data)
      reportDiff(newPreState, postState)

  `testImpl _ slots _ identifier`()

suite "EF - Phase 0 - Sanity - Slots " & preset():
  for kind, path in walkDir(SanitySlotsDir, relative = true, checkDir = true):
    runTest(path)
