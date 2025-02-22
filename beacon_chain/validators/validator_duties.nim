# beacon_chain
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  # Standard library
  std/[os, osproc, sequtils, streams, tables],

  # Nimble packages
  stew/[assign2, byteutils, objects],
  chronos, metrics,
  chronicles, chronicles/timings,
  json_serialization/std/[options, sets, net], serialization/errors,
  eth/db/kvstore,
  eth/keys, eth/p2p/discoveryv5/[protocol, enr],
  web3/ethtypes,

  # Local modules
  ../spec/datatypes/[phase0, altair, merge],
  ../spec/[
    eth2_merkleization, forks, helpers, network, signatures, state_transition,
    validator],
  ../consensus_object_pools/[
    spec_cache, blockchain_dag, block_clearance, attestation_pool, exit_pool,
    sync_committee_msg_pool],
  ../eth1/eth1_monitor,
  ../networking/eth2_network,
  ../sszdump, ../sync/sync_manager,
  ../gossip_processing/[block_processor, consensus_manager],
  ".."/[conf, beacon_clock, beacon_node, version],
  "."/[slashing_protection, validator_pool, keystore_management]

# Metrics for tracking attestation and beacon block loss
const delayBuckets = [-Inf, -4.0, -2.0, -1.0, -0.5, -0.1, -0.05,
                      0.05, 0.1, 0.5, 1.0, 2.0, 4.0, 8.0, Inf]

declareCounter beacon_attestations_sent,
  "Number of beacon chain attestations sent by this peer"

declareHistogram beacon_attestation_sent_delay,
  "Time(s) between slot start and attestation sent moment",
  buckets = delayBuckets

declareCounter beacon_sync_committee_messages_sent,
  "Number of sync committee messages sent by this peer"

declareCounter beacon_sync_committee_contributions_sent,
  "Number of sync committee contributions sent by this peer"

declareHistogram beacon_sync_committee_message_sent_delay,
  "Time(s) between slot start and sync committee message sent moment",
  buckets = delayBuckets

declareCounter beacon_blocks_proposed,
  "Number of beacon chain blocks sent by this peer"

declareGauge(attached_validator_balance,
  "Validator balance at slot end of the first 64 validators, in Gwei",
  labels = ["pubkey"])

declarePublicGauge(attached_validator_balance_total,
  "Validator balance of all attached validators, in Gwei")

logScope: topics = "beacval"

type
  SendResult* = Result[void, cstring]
  SendBlockResult* = Result[bool, cstring]
  ForkedBlockResult* = Result[ForkedBeaconBlock, string]

proc findValidator(validators: auto, pubkey: ValidatorPubKey):
    Option[ValidatorIndex] =
  let idx = validators.findIt(it.pubkey == pubkey)
  if idx == -1:
    # We allow adding a validator even if its key is not in the state registry:
    # it might be that the deposit for this validator has not yet been processed
    notice "Validator deposit not yet processed, monitoring", pubkey
    none(ValidatorIndex)
  else:
    some(idx.ValidatorIndex)

proc addLocalValidator(node: BeaconNode,
                       validators: auto,
                       item: KeystoreData) =
  let
    pubkey = item.pubkey
    index = findValidator(validators, pubkey)
  node.attachedValidators[].addLocalValidator(item, index)

proc addRemoteValidator(node: BeaconNode, validators: auto,
                        item: KeystoreData) =
  let httpFlags =
    block:
      var res: set[HttpClientFlag]
      if RemoteKeystoreFlag.IgnoreSSLVerification in item.flags:
        res.incl({HttpClientFlag.NoVerifyHost,
                  HttpClientFlag.NoVerifyServerName})
      res
  let prestoFlags = {RestClientFlag.CommaSeparatedArray}
  let client = RestClientRef.new($item.remoteUrl, prestoFlags, httpFlags)
  if client.isErr():
    warn "Unable to resolve remote signer address",
         remote_url = $item.remoteUrl, validator = item.pubkey
    return
  let index = findValidator(validators, item.pubkey)
  node.attachedValidators[].addRemoteValidator(item, client.get(), index)

proc addLocalValidators*(node: BeaconNode,
                         validators: openArray[KeystoreData]) =
  withState(node.dag.headState.data):
    for item in validators:
      node.addLocalValidator(state.data.validators.asSeq(), item)

proc addRemoteValidators*(node: BeaconNode,
                          validators: openArray[KeystoreData]) =
  withState(node.dag.headState.data):
    for item in validators:
      node.addRemoteValidator(state.data.validators.asSeq(), item)

proc addValidators*(node: BeaconNode) =
  let (localValidators, remoteValidators) =
    block:
      var local, remote: seq[KeystoreData]
      for keystore in listLoadableKeystores(node.config):
        case keystore.kind
        of KeystoreKind.Local:
          local.add(keystore)
        of KeystoreKind.Remote:
          remote.add(keystore)
      (local, remote)
  node.addLocalValidators(localValidators)
  node.addRemoteValidators(remoteValidators)

proc getAttachedValidator*(node: BeaconNode,
                           pubkey: ValidatorPubKey): AttachedValidator =
  node.attachedValidators[].getValidator(pubkey)

proc getAttachedValidator*(node: BeaconNode,
                           state_validators: auto,
                           idx: ValidatorIndex): AttachedValidator =
  if uint64(idx) < state_validators.lenu64:
    let validator = node.getAttachedValidator(state_validators[idx].pubkey)
    if validator != nil and validator.index != some(idx):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index  = some(idx)
    validator
  else:
    warn "Validator index out of bounds",
      idx, validators = state_validators.len
    nil

proc getAttachedValidator*(node: BeaconNode,
                           epochRef: EpochRef,
                           idx: ValidatorIndex): AttachedValidator =
  let key = epochRef.validatorKey(idx)
  if key.isSome():
    let validator = node.getAttachedValidator(key.get().toPubKey())
    if validator != nil and validator.index != some(idx):
      # Update index, in case the validator was activated!
      notice "Validator activated", pubkey = validator.pubkey, index = idx
      validator.index = some(idx)
    validator
  else:
    warn "Validator key not found",
      idx, epoch = epochRef.epoch
    nil

proc isSynced*(node: BeaconNode, head: BlockRef): bool =
  ## TODO This function is here as a placeholder for some better heurestics to
  ##      determine if we're in sync and should be producing blocks and
  ##      attestations. Generally, the problem is that slot time keeps advancing
  ##      even when there are no blocks being produced, so there's no way to
  ##      distinguish validators geniunely going missing from the node not being
  ##      well connected (during a network split or an internet outage for
  ##      example). It would generally be correct to simply keep running as if
  ##      we were the only legit node left alive, but then we run into issues:
  ##      with enough many empty slots, the validator pool is emptied leading
  ##      to empty committees and lots of empty slot processing that will be
  ##      thrown away as soon as we're synced again.

  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()

  # TODO if everyone follows this logic, the network will not recover from a
  #      halt: nobody will be producing blocks because everone expects someone
  #      else to do it
  if wallSlot.afterGenesis and head.slot + node.config.syncHorizon < wallSlot.slot:
    false
  else:
    true

func isGoodForSending(validationResult: ValidationRes): bool =
  # Validator clients such as Vouch can be configured to work with multiple
  # beacon nodes simultaneously. In this configuration, the validator client
  # will try to broadcast the gossip messages through each of the connected
  # beacon nodes which may lead to a situation where some of the nodes see a
  # message arriving from the network before it arrives through the REST API.
  # This should not be considered an error and the beacon node should still
  # broadcast the message as the intented purpose of the Vouch strategy is
  # to ensure that the message will reach as many peers as possible.
  validationResult.isOk() or validationResult.error[0] == ValidationResult.Ignore

proc sendAttestation*(
    node: BeaconNode, attestation: Attestation,
    subnet_id: SubnetId, checkSignature: bool): Future[SendResult] {.async.} =
  # Validate attestation before sending it via gossip - validation will also
  # register the attestation with the attestation pool. Notably, although
  # libp2p calls the data handler for any subscription on the subnet
  # topic, it does not perform validation.
  let res = await node.processor.attestationValidator(
    MsgSource.api, attestation, subnet_id, checkSignature)

  return
    if res.isGoodForSending:
      node.network.broadcastAttestation(subnet_id, attestation)
      beacon_attestations_sent.inc()
      if not(isNil(node.onAttestationSent)):
        node.onAttestationSent(attestation)
      ok()
    else:
      notice "Produced attestation failed validation",
        attestation = shortLog(attestation),
        error = res.error()
      err(res.error()[1])

proc sendSyncCommitteeMessage*(
    node: BeaconNode, msg: SyncCommitteeMessage,
    subcommitteeIdx: SyncSubcommitteeIndex,
    checkSignature: bool): Future[SendResult] {.async.} =
  # Validate sync committee message before sending it via gossip
  # validation will also register the message with the sync committee
  # message pool. Notably, although libp2p calls the data handler for
  # any subscription on the subnet topic, it does not perform validation.
  let res = await node.processor.syncCommitteeMessageValidator(
    MsgSource.api, msg, subcommitteeIdx, checkSignature)

  return
    if res.isGoodForSending:
      node.network.broadcastSyncCommitteeMessage(msg, subcommitteeIdx)
      beacon_sync_committee_messages_sent.inc()
      SendResult.ok()
    else:
      notice "Sync committee message failed validation",
             msg, error = res.error()
      SendResult.err(res.error()[1])

proc sendSyncCommitteeMessages*(node: BeaconNode,
                                msgs: seq[SyncCommitteeMessage]
                               ): Future[seq[SendResult]] {.async.} =
  return withState(node.dag.headState.data):
    when stateFork >= BeaconStateFork.Altair:
      var statuses = newSeq[Option[SendResult]](len(msgs))

      let
        curPeriod = sync_committee_period(state.data.slot)
        nextPeriod = curPeriod + 1

      let (keysCur, keysNxt) =
        block:
          var resCur: Table[uint64, int]
          var resNxt: Table[uint64, int]

          for index, msg in msgs.pairs():
            if msg.validator_index < lenu64(state.data.validators):
              let msgPeriod = sync_committee_period(msg.slot)
              if msgPeriod == curPeriod:
                resCur[msg.validator_index] = index
              elif msgPeriod == nextPeriod:
                resNxt[msg.validator_index] = index
              else:
                statuses[index] =
                  some(SendResult.err("Message's slot out of state's head range"))
            else:
              statuses[index] = some(SendResult.err("Incorrect validator's index"))
          if (len(resCur) == 0) and (len(resNxt) == 0):
            return statuses.mapIt(it.get())
          (resCur, resNxt)

      let (pending, indices) = block:
        var resFutures: seq[Future[SendResult]]
        var resIndices: seq[int]
        for subcommitteeIdx in SyncSubcommitteeIndex:
          for valKey in syncSubcommittee(
              node.dag.headSyncCommittees.current_sync_committee, subcommitteeIdx):
            let index = keysCur.getOrDefault(uint64(valKey), -1)
            if index >= 0:
              resIndices.add(index)
              resFutures.add(node.sendSyncCommitteeMessage(msgs[index],
                                                          subcommitteeIdx, true))
        for subcommitteeIdx in SyncSubcommitteeIndex:
          for valKey in syncSubcommittee(
              node.dag.headSyncCommittees.next_sync_committee, subcommitteeIdx):
            let index = keysNxt.getOrDefault(uint64(valKey), -1)
            if index >= 0:
              resIndices.add(index)
              resFutures.add(node.sendSyncCommitteeMessage(msgs[index],
                                                          subcommitteeIdx, true))
        (resFutures, resIndices)

      await allFutures(pending)

      for index, future in pending.pairs():
        if future.done():
          let fres = future.read()
          if fres.isErr():
            statuses[indices[index]] = some(SendResult.err(fres.error()))
          else:
            statuses[indices[index]] = some(SendResult.ok())
        elif future.failed() or future.cancelled():
          let exc = future.readError()
          debug "Unexpected failure while sending committee message",
            message = msgs[indices[index]], error = $exc.msg
          statuses[indices[index]] = some(SendResult.err(
            "Unexpected failure while sending committee message"))

      var res: seq[SendResult]
      for item in statuses:
        if item.isSome():
          res.add(item.get())
        else:
          res.add(SendResult.err("Message validator not in sync committee"))
      res
    else:
      var res: seq[SendResult]
      for _ in msgs:
        res.add(SendResult.err("Waiting for altair fork"))
      res

proc sendSyncCommitteeContribution*(
    node: BeaconNode,
    msg: SignedContributionAndProof,
    checkSignature: bool): Future[SendResult] {.async.} =
  let res = await node.processor.contributionValidator(
    MsgSource.api, msg, checkSignature)

  return
    if res.isGoodForSending:
      node.network.broadcastSignedContributionAndProof(msg)
      beacon_sync_committee_contributions_sent.inc()
      ok()
    else:
      notice "Sync committee contribution failed validation",
              msg, error = res.error()
      err(res.error()[1])

proc createAndSendAttestation(node: BeaconNode,
                              fork: Fork,
                              genesis_validators_root: Eth2Digest,
                              validator: AttachedValidator,
                              attestationData: AttestationData,
                              committeeLen: int,
                              indexInCommittee: int,
                              subnet_id: SubnetId) {.async.} =
  try:
    var attestation =
      block:
        let res = await validator.produceAndSignAttestation(
          attestationData, committeeLen, indexInCommittee, fork,
          genesis_validators_root)
        if res.isErr():
          error "Unable to sign attestation", validator = shortLog(validator),
                error_msg = res.error()
          return
        res.get()

    let res = await node.sendAttestation(
      attestation, subnet_id, checkSignature = false)
    if not res.isOk(): # Logged in sendAttestation
      return

    if node.config.dumpEnabled:
      dump(node.config.dumpDirOutgoing, attestation.data,
           validator.pubkey)

    let wallTime = node.beaconClock.now()
    let deadline = attestationData.slot.attestation_deadline()

    let (delayStr, delaySecs) =
      if wallTime < deadline:
        ("-" & $(deadline - wallTime), -toFloatSeconds(deadline - wallTime))
      else:
        ($(wallTime - deadline), toFloatSeconds(wallTime - deadline))

    notice "Attestation sent",
      attestation = shortLog(attestation), validator = shortLog(validator),
      delay = delayStr, subnet_id

    beacon_attestation_sent_delay.observe(delaySecs)
  except CatchableError as exc:
    # An error could happen here when the signature task fails - we must
    # not leak the exception because this is an asyncSpawn task
    notice "Error sending attestation", err = exc.msg

proc getBlockProposalEth1Data*(node: BeaconNode,
                               state: ForkedHashedBeaconState):
                               BlockProposalEth1Data =
  if node.eth1Monitor.isNil:
    var pendingDepositsCount =
      getStateField(state, eth1_data).deposit_count -
        getStateField(state, eth1_deposit_index)
    if pendingDepositsCount > 0:
      result.hasMissingDeposits = true
    else:
      result.vote = getStateField(state, eth1_data)
  else:
    let finalizedEpochRef = node.dag.getFinalizedEpochRef()
    result = node.eth1Monitor.getBlockProposalData(
      state, finalizedEpochRef.eth1_data,
      finalizedEpochRef.eth1_deposit_index)

proc forkchoice_updated(state: merge.BeaconState,
                        head_block_hash: Eth2Digest,
                        finalized_block_hash: Eth2Digest,
                        fee_recipient: ethtypes.Address,
                        execution_engine: Web3DataProviderRef):
                        Future[Option[merge.PayloadId]] {.async.} =
  let
    timestamp = compute_timestamp_at_slot(state, state.slot)
    random = get_randao_mix(state, get_current_epoch(state))
    payloadId =
      (await execution_engine.forkchoiceUpdated(
        head_block_hash, finalized_block_hash, timestamp, random.data,
        fee_recipient)).payloadId
  return if payloadId.isSome:
    some(merge.PayloadId(payloadId.get))
  else:
    none(merge.PayloadId)

proc makeBeaconBlockForHeadAndSlot*(node: BeaconNode,
                                    randao_reveal: ValidatorSig,
                                    validator_index: ValidatorIndex,
                                    graffiti: GraffitiBytes,
                                    head: BlockRef, slot: Slot
                                   ): Future[ForkedBlockResult] {.async.} =
  # Advance state to the slot that we're proposing for
  let
    proposalState = assignClone(node.dag.headState)

  node.dag.withUpdatedState(proposalState[], head.atSlot(slot - 1)) do:
    # Advance to the given slot without calculating state root - we'll only
    # need a state root _with_ the block applied
    var info: ForkedEpochInfo
    if not process_slots(
        node.dag.cfg, stateData.data, slot, cache, info,
        {skipLastStateRootCalculation}):
      return ForkedBlockResult.err("Unable to advance state to slot")

    let
      eth1Proposal = node.getBlockProposalEth1Data(stateData.data)

    if eth1Proposal.hasMissingDeposits:
      error "Eth1 deposits not available. Skipping block proposal", slot
      return ForkedBlockResult.err("Eth1 deposits not available")

    let exits = withState(stateData.data):
      node.exitPool[].getBeaconBlockExits(state.data)
    return makeBeaconBlock(
      node.dag.cfg,
      stateData.data,
      validator_index,
      randao_reveal,
      eth1Proposal.vote,
      graffiti,
      node.attestationPool[].getAttestationsForBlock(stateData.data, cache),
      eth1Proposal.deposits,
      exits,
      if slot.epoch < node.dag.cfg.ALTAIR_FORK_EPOCH:
        SyncAggregate.init()
      else:
        node.sync_committee_msg_pool[].produceSyncAggregate(head.root),
      default(merge.ExecutionPayload),
      noRollback, # Temporary state - no need for rollback
      cache)
  do:
    warn "Cannot get proposal state - skipping block productioon, database corrupt?",
      head = shortLog(head),
      slot

proc proposeBlock(node: BeaconNode,
                  validator: AttachedValidator,
                  validator_index: ValidatorIndex,
                  head: BlockRef,
                  slot: Slot): Future[BlockRef] {.async.} =
  if head.slot >= slot:
    # We should normally not have a head newer than the slot we're proposing for
    # but this can happen if block proposal is delayed
    warn "Skipping proposal, have newer head already",
      headSlot = shortLog(head.slot),
      headBlockRoot = shortLog(head.root),
      slot = shortLog(slot)
    return head

  let
    fork = node.dag.forkAtEpoch(slot.epoch)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)
    randao =
      block:
        let res = await validator.genRandaoReveal(fork, genesis_validators_root,
                                                  slot)
        if res.isErr():
          error "Unable to generate randao reveal",
                validator = shortLog(validator), error_msg = res.error()
          return head
        res.get()

  var newBlock = await makeBeaconBlockForHeadAndSlot(
    node, randao, validator_index, node.graffitiBytes, head, slot)

  if newBlock.isErr():
    return head # already logged elsewhere!

  let forkedBlck = newBlock.get()

  withBlck(forkedBlck):
    let
      blockRoot = hash_tree_root(blck)
      signing_root = compute_block_signing_root(
        fork, genesis_validators_root, slot, blockRoot)

      notSlashable = node.attachedValidators
        .slashingProtection
        .registerBlock(validator_index, validator.pubkey, slot, signing_root)

    if notSlashable.isErr:
      warn "Slashing protection activated",
        validator = validator.pubkey,
        slot = slot,
        existingProposal = notSlashable.error
      return head

    let
      signature =
        block:
          let res = await validator.signBlockProposal(
            fork, genesis_validators_root, slot, blockRoot, forkedBlck)
          if res.isErr():
            error "Unable to sign block proposal",
                  validator = shortLog(validator), error_msg = res.error()
            return head
          res.get()
      signedBlock =
        when blck is phase0.BeaconBlock:
          phase0.SignedBeaconBlock(
            message: blck, signature: signature, root: blockRoot)
        elif blck is altair.BeaconBlock:
          altair.SignedBeaconBlock(
            message: blck, signature: signature, root: blockRoot)
        elif blck is merge.BeaconBlock:
          merge.SignedBeaconBlock(
            message: blck, signature: signature, root: blockRoot)
        else:
          static: doAssert "Unkown block type"

    # We produced the block using a state transition, meaning the block is valid
    # enough that it will not be rejected by gossip - it is unlikely but
    # possible that it will be ignored due to extreme timing conditions, for
    # example a delay in signing.
    # We'll start broadcasting it before integrating fully in the chaindag
    # so that it can start propagating through the network ASAP.
    node.network.broadcastBeaconBlock(signedBlock)

    let
      wallTime = node.beaconClock.now()

      # storeBlock puts the block in the chaindag, and if accepted, takes care
      # of side effects such as event api notification
      newBlockRef = node.blockProcessor[].storeBlock(
        MsgSource.api, wallTime, signedBlock)

    if newBlockRef.isErr:
      warn "Unable to add proposed block to block pool",
        blockRoot = shortLog(blockRoot), blck = shortLog(blck),
        signature = shortLog(signature), validator = shortLog(validator)
      return head

    notice "Block proposed",
      blockRoot = shortLog(blockRoot), blck = shortLog(blck),
      signature = shortLog(signature), validator = shortLog(validator)

    beacon_blocks_proposed.inc()

    return newBlockRef.get()

proc handleAttestations(node: BeaconNode, head: BlockRef, slot: Slot) =
  ## Perform all attestations that the validators attached to this node should
  ## perform during the given slot
  if slot + SLOTS_PER_EPOCH < head.slot:
    # The latest block we know about is a lot newer than the slot we're being
    # asked to attest to - this makes it unlikely that it will be included
    # at all.
    # TODO the oldest attestations allowed are those that are older than the
    #      finalized epoch.. also, it seems that posting very old attestations
    #      is risky from a slashing perspective. More work is needed here.
    warn "Skipping attestation, head is too recent",
      head = shortLog(head),
      slot = shortLog(slot)
    return

  let attestationHead = head.atSlot(slot)
  if head != attestationHead.blck:
    # In rare cases, such as when we're busy syncing or just slow, we'll be
    # attesting to a past state - we must then recreate the world as it looked
    # like back then
    notice "Attesting to a state in the past, falling behind?",
      attestationHead = shortLog(attestationHead),
      head = shortLog(head)

  trace "Checking attestations",
    attestationHead = shortLog(attestationHead),
    head = shortLog(head)

  # We need to run attestations exactly for the slot that we're attesting to.
  # In case blocks went missing, this means advancing past the latest block
  # using empty slots as fillers.
  # https://github.com/ethereum/consensus-specs/blob/v1.1.8/specs/phase0/validator.md#validator-assignments
  let
    epochRef = block:
      let tmp = node.dag.getEpochRef(attestationHead.blck, slot.epoch, false)
      if isErr(tmp):
        warn "Cannot construct EpochRef for attestation head, report bug",
          attestationHead = shortLog(attestationHead), slot
        return
      tmp.get()
    committees_per_slot = get_committee_count_per_slot(epochRef)
    fork = node.dag.forkAtEpoch(slot.epoch)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)

  for committee_index in get_committee_indices(committees_per_slot):
    let committee = get_beacon_committee(epochRef, slot, committee_index)

    for index_in_committee, validator_index in committee:
      let validator = node.getAttachedValidator(epochRef, validator_index)
      if validator == nil:
        continue

      let
        data = makeAttestationData(epochRef, attestationHead, committee_index)
        # TODO signing_root is recomputed in produceAndSignAttestation/signAttestation just after
        signing_root = compute_attestation_signing_root(
          fork, genesis_validators_root, data)
        registered = node.attachedValidators
          .slashingProtection
          .registerAttestation(
            validator_index,
            validator.pubkey,
            data.source.epoch,
            data.target.epoch,
            signing_root)
      if registered.isOk():
        let subnet_id = compute_subnet_for_attestation(
          committees_per_slot, data.slot, committee_index)
        asyncSpawn createAndSendAttestation(
          node, fork, genesis_validators_root, validator, data,
          committee.len(), index_in_committee, subnet_id)
      else:
        warn "Slashing protection activated for attestation",
          validator = validator.pubkey,
          badVoteDetails = $registered.error()

proc createAndSendSyncCommitteeMessage(node: BeaconNode,
                                       slot: Slot,
                                       validator: AttachedValidator,
                                       subcommitteeIdx: SyncSubcommitteeIndex,
                                       head: BlockRef) {.async.} =
  try:
    let
      fork = node.dag.forkAtEpoch(slot.epoch)
      genesisValidatorsRoot = node.dag.genesisValidatorsRoot
      msg =
        block:
          let res = await signSyncCommitteeMessage(validator, fork,
                                                   genesisValidatorsRoot,
                                                   slot, head.root)
          if res.isErr():
            error "Unable to sign committee message using remote signer",
                  validator = shortLog(validator), slot = slot,
                  block_root = shortLog(head.root)
            return
          res.get()

    let res = await node.sendSyncCommitteeMessage(
      msg, subcommitteeIdx, checkSignature = false)
    if res.isErr():
      # Logged in sendSyncCommitteeMessage
      return

    if node.config.dumpEnabled:
      dump(node.config.dumpDirOutgoing, msg, validator.pubkey)

    let
      wallTime = node.beaconClock.now()
      deadline = msg.slot.start_beacon_time() + syncCommitteeMessageSlotOffset

    let (delayStr, delaySecs) =
      if wallTime < deadline:
        ("-" & $(deadline - wallTime), -toFloatSeconds(deadline - wallTime))
      else:
        ($(wallTime - deadline), toFloatSeconds(wallTime - deadline))

    notice "Sync committee message sent",
            message = shortLog(msg),
            validator = shortLog(validator),
            delay = delayStr

    beacon_sync_committee_message_sent_delay.observe(delaySecs)
  except CatchableError as exc:
    # An error could happen here when the signature task fails - we must
    # not leak the exception because this is an asyncSpawn task
    notice "Error sending sync committee message", err = exc.msg

proc handleSyncCommitteeMessages(node: BeaconNode, head: BlockRef, slot: Slot) =
  # TODO Use a view type to avoid the copy
  var syncCommittee = node.dag.syncCommitteeParticipants(slot + 1)

  for subcommitteeIdx in SyncSubcommitteeIndex:
    for valIdx in syncSubcommittee(syncCommittee, subcommitteeIdx):
      let validator = node.getAttachedValidator(
        getStateField(node.dag.headState.data, validators), valIdx)
      if isNil(validator) or validator.index.isNone():
        continue
      asyncSpawn createAndSendSyncCommitteeMessage(node, slot, validator,
                                                   subcommitteeIdx, head)

proc signAndSendContribution(node: BeaconNode,
                             validator: AttachedValidator,
                             contribution: SyncCommitteeContribution,
                             selectionProof: ValidatorSig) {.async.} =
  try:
    let msg = (ref SignedContributionAndProof)(
      message: ContributionAndProof(
        aggregator_index: uint64 validator.index.get,
        contribution: contribution,
        selection_proof: selectionProof))

    let res = await validator.sign(
      msg, node.dag.forkAtEpoch(contribution.slot.epoch),
      node.dag.genesisValidatorsRoot)

    if res.isErr():
      error "Unable to sign sync committee contribution usign remote signer",
            validator = shortLog(validator), error_msg = res.error()
      return

    # Failures logged in sendSyncCommitteeContribution
    discard await node.sendSyncCommitteeContribution(msg[], false)
    notice "Contribution sent", contribution = shortLog(msg[])
  except CatchableError as exc:
    # An error could happen here when the signature task fails - we must
    # not leak the exception because this is an asyncSpawn task
    notice "Error sending sync committee contribution", err = exc.msg

proc handleSyncCommitteeContributions(node: BeaconNode,
                                      head: BlockRef, slot: Slot) {.async.} =
  # TODO Use a view type to avoid the copy
  let
    fork = node.dag.forkAtEpoch(slot.epoch)
    genesisValidatorsRoot = node.dag.genesisValidatorsRoot
    syncCommittee = node.dag.syncCommitteeParticipants(slot + 1)

  type
    AggregatorCandidate = object
      validator: AttachedValidator
      subcommitteeIdx: SyncSubcommitteeIndex

  var candidateAggregators: seq[AggregatorCandidate]
  var selectionProofs: seq[Future[SignatureResult]]

  var time = timeIt:
    for subcommitteeIdx in SyncSubcommitteeIndex:
      # TODO Hoist outside of the loop with a view type
      #      to avoid the repeated offset calculations
      for valIdx in syncSubcommittee(syncCommittee, subcommitteeIdx):
        let validator = node.getAttachedValidator(
          getStateField(node.dag.headState.data, validators), valIdx)
        if validator == nil:
          continue

        candidateAggregators.add AggregatorCandidate(
          validator: validator,
          subcommitteeIdx: subcommitteeIdx)

        selectionProofs.add validator.getSyncCommitteeSelectionProof(
          fork, genesisValidatorsRoot, slot, subcommitteeIdx.asUInt64)

    await allFutures(selectionProofs)

  debug "Prepared contributions selection proofs",
        count = selectionProofs.len, time

  var contributionsSent = 0

  time = timeIt:
    for i, proof in selectionProofs.pairs():
      if not proof.completed:
        continue

      let selectionProofRes = proof.read()
      if selectionProofRes.isErr():
        error "Unable to sign selection proof using remote signer",
              validator = shortLog(candidateAggregators[i].validator),
              slot, head, subnet_id = candidateAggregators[i].subcommitteeIdx
        continue
      let selectionProof = selectionProofRes.get()
      if not is_sync_committee_aggregator(selectionProof):
        continue

      var contribution: SyncCommitteeContribution
      let contributionWasProduced = node.syncCommitteeMsgPool[].produceContribution(
        slot,
        head.root,
        candidateAggregators[i].subcommitteeIdx,
        contribution)

      if contributionWasProduced:
        asyncSpawn signAndSendContribution(
          node,
          candidateAggregators[i].validator,
          contribution,
          selectionProof)
        inc contributionsSent
      else:
        debug "Failure to produce contribution",
              slot, head, subnet_id = candidateAggregators[i].subcommitteeIdx

proc handleProposal(node: BeaconNode, head: BlockRef, slot: Slot):
    Future[BlockRef] {.async.} =
  ## Perform the proposal for the given slot, iff we have a validator attached
  ## that is supposed to do so, given the shuffling at that slot for the given
  ## head - to compute the proposer, we need to advance a state to the given
  ## slot
  let proposer = node.dag.getProposer(head, slot)
  if proposer.isNone():
    return head

  let
    proposerKey = node.dag.validatorKey(proposer.get).get().toPubKey
    validator = node.attachedValidators[].getValidator(proposerKey)

  return
    if validator == nil:
      debug "Expecting block proposal",
        headRoot = shortLog(head.root),
        slot = shortLog(slot),
        proposer_index = proposer.get(),
        proposer = shortLog(proposerKey)

      head
    else:
      await proposeBlock(node, validator, proposer.get(), head, slot)

proc makeAggregateAndProof*(
    pool: var AttestationPool, epochRef: EpochRef, slot: Slot, index: CommitteeIndex,
    validatorIndex: ValidatorIndex, slot_signature: ValidatorSig): Option[AggregateAndProof] =
  doAssert validatorIndex in get_beacon_committee(epochRef, slot, index)

  # TODO for testing purposes, refactor this into the condition check
  # and just calculation
  # https://github.com/ethereum/consensus-specs/blob/v1.1.8/specs/phase0/validator.md#aggregation-selection
  if not is_aggregator(epochRef, slot, index, slot_signature):
    return none(AggregateAndProof)

  let maybe_slot_attestation = getAggregatedAttestation(pool, slot, index)
  if maybe_slot_attestation.isNone:
    return none(AggregateAndProof)

  # https://github.com/ethereum/consensus-specs/blob/v1.1.8/specs/phase0/validator.md#construct-aggregate
  # https://github.com/ethereum/consensus-specs/blob/v1.1.8/specs/phase0/validator.md#aggregateandproof
  some(AggregateAndProof(
    aggregator_index: validatorIndex.uint64,
    aggregate: maybe_slot_attestation.get,
    selection_proof: slot_signature))

proc sendAggregatedAttestations(
    node: BeaconNode, head: BlockRef, slot: Slot) {.async.} =
  # Aggregated attestations must be sent by members of the beacon committees for
  # the given slot, for which `is_aggregator` returns `true.

  let
    epochRef = block:
      let tmp = node.dag.getEpochRef(head, slot.epoch, false)
      if isErr(tmp): # Some unusual race condition perhaps?
        warn "Cannot construct EpochRef for head, report bug",
          head = shortLog(head), slot
        return
      tmp.get()

    fork = node.dag.forkAtEpoch(slot.epoch)
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)
    committees_per_slot = get_committee_count_per_slot(epochRef)

  var
    slotSigs: seq[Future[SignatureResult]] = @[]
    slotSigsData: seq[tuple[committee_index: CommitteeIndex,
                            validator_index: ValidatorIndex,
                            v: AttachedValidator]] = @[]

  for committee_index in get_committee_indices(committees_per_slot):
    let committee = get_beacon_committee(epochRef, slot, committee_index)

    for index_in_committee, validator_index in committee:
      let validator = node.getAttachedValidator(epochRef, validator_index)
      if validator != nil:
        # the validator index and private key pair.
        slotSigs.add getSlotSig(validator, fork,
          genesis_validators_root, slot)
        slotSigsData.add (committee_index, validator_index, validator)

  await allFutures(slotSigs)

  doAssert slotSigsData.len == slotSigs.len
  for i in 0..<slotSigs.len:
    let
      slotSig = slotSigs[i].read()
      data = slotSigsData[i]
    if slotSig.isErr():
      error "Unable to create slot signature using remote signer",
            validator = shortLog(data.v),
            slot, error_msg = slotSig.error()
      continue
    let aggregateAndProof =
      makeAggregateAndProof(node.attestationPool[], epochRef, slot,
                            data.committee_index,
                            data.validator_index,
                            slotSig.get())

    # Don't broadcast when, e.g., this node isn't aggregator
    if aggregateAndProof.isSome:
      let sig =
        block:
          let res = await signAggregateAndProof(data.v,
            aggregateAndProof.get, fork, genesis_validators_root)
          if res.isErr():
            error "Unable to sign aggregated attestation using remote signer",
                  validator = shortLog(data.v), error_msg = res.error()
            return
          res.get()
      var signedAP = SignedAggregateAndProof(
        message: aggregateAndProof.get,
        signature: sig)
      node.network.broadcastAggregateAndProof(signedAP)
      # The subnet on which the attestations (should have) arrived
      let subnet_id = compute_subnet_for_attestation(
        committees_per_slot, slot, data.committee_index)
      notice "Aggregated attestation sent",
        attestation = shortLog(signedAP.message.aggregate),
        aggregator_index = signedAP.message.aggregator_index,
        signature = shortLog(signedAP.signature),
        validator = shortLog(data.v),
        subnet_id

proc updateValidatorMetrics*(node: BeaconNode) =
  # Technically, this only needs to be done on epoch transitions and if there's
  # a reorg that spans an epoch transition, but it's easier to implement this
  # way for now.

  # We'll limit labelled metrics to the first 64, so that we don't overload
  # Prometheus.

  var total: Gwei
  var i = 0
  for _, v in node.attachedValidators[].validators:
    let balance =
      if v.index.isNone():
        0.Gwei
      elif v.index.get().uint64 >=
          getStateField(node.dag.headState.data, balances).lenu64:
        debug "Cannot get validator balance, index out of bounds",
          pubkey = shortLog(v.pubkey), index = v.index.get(),
          balances = getStateField(node.dag.headState.data, balances).len,
          stateRoot = getStateRoot(node.dag.headState.data)
        0.Gwei
      else:
        getStateField(node.dag.headState.data, balances).asSeq()[v.index.get()]

    if i < 64:
      attached_validator_balance.set(
        balance.toGaugeValue, labelValues = [shortLog(v.pubkey)])

    inc i
    total += balance

  node.attachedValidatorBalanceTotal = total
  attached_validator_balance_total.set(total.toGaugeValue)

proc handleValidatorDuties*(node: BeaconNode, lastSlot, slot: Slot) {.async.} =
  ## Perform validator duties - create blocks, vote and aggregate existing votes
  if node.attachedValidators[].count == 0:
    # Nothing to do because we have no validator attached
    return

  # The dag head might be updated by sync while we're working due to the
  # await calls, thus we use a local variable to keep the logic straight here
  var head = node.dag.head
  if not node.isSynced(head):
    let
      nextAttestationSlot = node.actionTracker.getNextAttestationSlot(slot)
      nextProposalSlot = node.actionTracker.getNextProposalSlot(slot)
    if slot in [nextAttestationSlot, nextProposalSlot]:
      notice "Syncing in progress; skipping validator duties for now",
        slot, headSlot = head.slot
    else:
      debug "Syncing in progress; skipping validator duties for now",
        slot, headSlot = head.slot

    # Rewards will be growing though, as we sync..
    updateValidatorMetrics(node)

    return

  var curSlot = lastSlot + 1

  # If broadcastStartEpoch is 0, it hasn't had time to initialize yet, which
  # means that it'd be okay not to continue, but it won't gossip regardless.
  if curSlot.epoch <
        node.processor[].doppelgangerDetection.broadcastStartEpoch and
      node.config.doppelgangerDetection:
    let
      nextAttestationSlot = node.actionTracker.getNextAttestationSlot(slot)
      nextProposalSlot = node.actionTracker.getNextProposalSlot(slot)

    if slot in [nextAttestationSlot, nextProposalSlot]:
      notice "Doppelganger detection active - skipping validator duties while observing activity on the network",
        slot, epoch = slot.epoch, nextAttestationSlot, nextProposalSlot,
        broadcastStartEpoch =
          node.processor[].doppelgangerDetection.broadcastStartEpoch
    else:
      debug "Doppelganger detection active - skipping validator duties while observing activity on the network",
        slot, epoch = slot.epoch, nextAttestationSlot, nextProposalSlot,
        broadcastStartEpoch =
          node.processor[].doppelgangerDetection.broadcastStartEpoch

    return

  # Start by checking if there's work we should have done in the past that we
  # can still meaningfully do
  while curSlot < slot:
    notice "Catching up on validator duties",
      curSlot = shortLog(curSlot),
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot)

    # For every slot we're catching up, we'll propose then send
    # attestations - head should normally be advancing along the same branch
    # in this case
    head = await handleProposal(node, head, curSlot)

    # For each slot we missed, we need to send out attestations - if we were
    # proposing during this time, we'll use the newly proposed head, else just
    # keep reusing the same - the attestation that goes out will actually
    # rewind the state to what it looked like at the time of that slot
    handleAttestations(node, head, curSlot)

    curSlot += 1

  head = await handleProposal(node, head, slot)

  let
    # The latest point in time when we'll be sending out attestations
    attestationCutoff = node.beaconClock.fromNow(slot.attestation_deadline())

  if attestationCutoff.inFuture:
    debug "Waiting to send attestations",
      head = shortLog(head),
      attestationCutoff = shortLog(attestationCutoff.offset)

    # Wait either for the block or the attestation cutoff time to arrive
    if await node.consensusManager[].expectBlock(slot).withTimeout(attestationCutoff.offset):
      # The expected block arrived (or expectBlock was called again which
      # shouldn't happen as this is the only place we use it) - in our async
      # loop however, we might have been doing other processing that caused delays
      # here so we'll cap the waiting to the time when we would have sent out
      # attestations had the block not arrived.
      # An opposite case is that we received (or produced) a block that has
      # not yet reached our neighbours. To protect against our attestations
      # being dropped (because the others have not yet seen the block), we'll
      # impose a minimum delay of 1000ms. The delay is enforced only when we're
      # not hitting the "normal" cutoff time for sending out attestations.
      # An earlier delay of 250ms has proven to be not enough, increasing the
      # risk of losing attestations.
      # Regardless, because we "just" received the block, we'll impose the
      # delay.

      const afterBlockDelay = 1000
      let
        afterBlockTime = node.beaconClock.now() + millis(afterBlockDelay)
        afterBlockCutoff = node.beaconClock.fromNow(
          min(afterBlockTime, slot.attestation_deadline() + millis(afterBlockDelay)))

      if afterBlockCutoff.inFuture:
        debug "Got block, waiting to send attestations",
          head = shortLog(head),
          afterBlockCutoff = shortLog(afterBlockCutoff.offset)

        await sleepAsync(afterBlockCutoff.offset)

    # Time passed - we might need to select a new head in that case
    node.consensusManager[].updateHead(slot)
    head = node.dag.head

  static: doAssert attestationSlotOffset == syncCommitteeMessageSlotOffset

  handleAttestations(node, head, slot)
  handleSyncCommitteeMessages(node, head, slot)

  updateValidatorMetrics(node) # the important stuff is done, update the vanity numbers

  # https://github.com/ethereum/consensus-specs/blob/v1.1.8/specs/phase0/validator.md#broadcast-aggregate
  # If the validator is selected to aggregate (`is_aggregator`), then they
  # broadcast their best aggregate as a `SignedAggregateAndProof` to the global
  # aggregate channel (`beacon_aggregate_and_proof`) `2 / INTERVALS_PER_SLOT`
  # of the way through the `slot`-that is,
  # `SECONDS_PER_SLOT * 2 / INTERVALS_PER_SLOT` seconds after the start of `slot`.
  if slot > 2:
    doAssert slot.aggregate_deadline() == slot.sync_contribution_deadline()
    let
      aggregateCutoff = node.beaconClock.fromNow(slot.aggregate_deadline())
    if aggregateCutoff.inFuture:
      debug "Waiting to send aggregate attestations",
        aggregateCutoff = shortLog(aggregateCutoff.offset)
      await sleepAsync(aggregateCutoff.offset)

    let sendAggregatedAttestationsFut =
      sendAggregatedAttestations(node, head, slot)

    let handleSyncCommitteeContributionsFut =
      handleSyncCommitteeContributions(node, head, slot)

    await handleSyncCommitteeContributionsFut
    await sendAggregatedAttestationsFut

proc sendAttestation*(node: BeaconNode,
                      attestation: Attestation): Future[SendResult] {.async.} =
  # REST/JSON-RPC API helper procedure.
  let
    target =
      block:
        let res = node.dag.getRef(attestation.data.target.root)
        if isNil(res):
          notice "Attempt to send attestation for unknown target",
                attestation = shortLog(attestation)
          return SendResult.err(
            "Attempt to send attestation for unknown block")
        res
    epochRef = block:
      let tmp = node.dag.getEpochRef(
        target, attestation.data.target.epoch, false)
      if tmp.isErr(): # Shouldn't happen
        warn "Cannot construct EpochRef for attestation, skipping send - report bug",
          target = shortLog(target),
          attestation = shortLog(attestation)
        return
      tmp.get()
    committee_index = block:
      let v = epochRef.get_committee_index(attestation.data.index)
      if v.isErr():
        notice "Invalid committee index in attestation",
          attestation = shortLog(attestation)
        return SendResult.err("Invalid committee index in attestation")
      v.get()

    subnet_id = compute_subnet_for_attestation(
      get_committee_count_per_slot(epochRef), attestation.data.slot,
      committee_index)
    res = await node.sendAttestation(attestation, subnet_id,
                                     checkSignature = true)
  if not res.isOk():
    return res

  let
    wallTime = node.processor.getCurrentBeaconTime()
    deadline = attestation.data.slot.attestation_deadline()
    (delayStr, delaySecs) =
      if wallTime < deadline:
        ("-" & $(deadline - wallTime), -toFloatSeconds(deadline - wallTime))
      else:
        ($(wallTime - deadline), toFloatSeconds(wallTime - deadline))

  notice "Attestation sent",
    attestation = shortLog(attestation), delay = delayStr, subnet_id

  beacon_attestation_sent_delay.observe(delaySecs)

  return SendResult.ok()

proc sendAggregateAndProof*(node: BeaconNode,
                            proof: SignedAggregateAndProof): Future[SendResult] {.
     async.} =
  # REST/JSON-RPC API helper procedure.
  let res = await node.processor.aggregateValidator(MsgSource.api, proof)
  return
    if res.isGoodForSending:
      node.network.broadcastAggregateAndProof(proof)

      notice "Aggregated attestation sent",
        attestation = shortLog(proof.message.aggregate),
        aggregator_index = proof.message.aggregator_index,
        signature = shortLog(proof.signature)

      ok()
    else:
      notice "Aggregate and proof failed validation",
            proof = shortLog(proof.message.aggregate), error = res.error()

      err(res.error()[1])

proc sendVoluntaryExit*(node: BeaconNode,
                        exit: SignedVoluntaryExit): SendResult =
  # REST/JSON-RPC API helper procedure.
  let res = node.processor[].voluntaryExitValidator(MsgSource.api, exit)
  if res.isGoodForSending:
    node.network.broadcastVoluntaryExit(exit)
    ok()
  else:
    notice "Voluntary exit request failed validation",
           exit = shortLog(exit.message), error = res.error()
    err(res.error()[1])

proc sendAttesterSlashing*(node: BeaconNode,
                           slashing: AttesterSlashing): SendResult =
  # REST/JSON-RPC API helper procedure.
  let res = node.processor[].attesterSlashingValidator(MsgSource.api, slashing)
  if res.isGoodForSending:
    node.network.broadcastAttesterSlashing(slashing)
    ok()
  else:
    notice "Attester slashing request failed validation",
           slashing = shortLog(slashing), error = res.error()
    err(res.error()[1])

proc sendProposerSlashing*(node: BeaconNode,
                           slashing: ProposerSlashing): SendResult =
  # REST/JSON-RPC API helper procedure.
  let res = node.processor[].proposerSlashingValidator(MsgSource.api, slashing)
  if res.isGoodForSending:
    node.network.broadcastProposerSlashing(slashing)
    ok()
  else:
    notice "Proposer slashing request failed validation",
           slashing = shortLog(slashing), error = res.error()
    err(res.error()[1])

proc sendBeaconBlock*(node: BeaconNode, forked: ForkedSignedBeaconBlock
                     ): Future[SendBlockResult] {.async.} =
  # REST/JSON-RPC API helper procedure.
  block:
    # Start with a quick gossip validation check such that broadcasting the
    # block doesn't get the node into trouble
    let res = withBlck(forked):
      when blck isnot merge.SignedBeaconBlock:
        validateBeaconBlock(
          node.dag, node.quarantine, blck, node.beaconClock.now(),
          {})
      else:
       return SendBlockResult.err(
        "TODO merge block proposal via REST not implemented")

    if not res.isGoodForSending():
      return SendBlockResult.err(res.error()[1])

  # The block passed basic gossip validation - we can "safely" broadcast it now.
  # In fact, per the spec, we should broadcast it even if it later fails to
  # apply to our state.
  node.network.broadcastBeaconBlock(forked)

  let
    wallTime = node.beaconClock.now()
    accepted = withBlck(forked):
      let newBlockRef = node.blockProcessor[].storeBlock(
        MsgSource.api, wallTime, blck)

      # The boolean we return tells the caller whether the block was integrated
      # into the chain
      if newBlockRef.isOk():
        notice "Block published",
          blockRoot = shortLog(blck.root), blck = shortLog(blck.message),
          signature = shortLog(blck.signature)
        true
      else:
        warn "Unable to add proposed block to block pool",
          blockRoot = shortLog(blck.root), blck = shortLog(blck.message),
          signature = shortLog(blck.signature), err = newBlockRef.error()

        false
  return SendBlockResult.ok(accepted)

proc registerDuty*(
    node: BeaconNode, slot: Slot, subnet_id: SubnetId, vidx: ValidatorIndex,
    isAggregator: bool) =
  # Only register relevant duties
  node.actionTracker.registerDuty(slot, subnet_id, vidx, isAggregator)

proc registerDuties*(node: BeaconNode, wallSlot: Slot) {.async.} =
  ## Register upcoming duties of attached validators with the duty tracker

  if node.attachedValidators[].count() == 0 or not node.isSynced(node.dag.head):
    # Nothing to do because we have no validator attached
    return

  let
    genesis_validators_root =
      getStateField(node.dag.headState.data, genesis_validators_root)
    head = node.dag.head

  # Getting the slot signature is expensive but cached - in "normal" cases we'll
  # be getting the duties one slot at a time
  for slot in wallSlot ..< wallSlot + SUBNET_SUBSCRIPTION_LEAD_TIME_SLOTS:
    let
      epochRef = block:
        let tmp = node.dag.getEpochRef(head, slot.epoch, false)
        if tmp.isErr(): # Shouldn't happen
          warn "Cannot construct EpochRef for duties - report bug",
            head = shortLog(head), slot
          return
        tmp.get()
    let
      fork = node.dag.forkAtEpoch(slot.epoch)
      committees_per_slot = get_committee_count_per_slot(epochRef)

    for committee_index in get_committee_indices(committees_per_slot):
      let committee = get_beacon_committee(epochRef, slot, committee_index)

      for index_in_committee, validator_index in committee:
        let validator = node.getAttachedValidator(epochRef, validator_index)
        if validator != nil:
          let
            subnet_id = compute_subnet_for_attestation(
              committees_per_slot, slot, committee_index)
          let slotSigRes = await getSlotSig(validator, fork,
                                            genesis_validators_root, slot)
          if slotSigRes.isErr():
            error "Unable to create slot signature using remote signer",
                  validator = shortLog(validator),
                  error_msg = slotSigRes.error()
            continue
          let isAggregator = is_aggregator(committee.lenu64, slotSigRes.get())

          node.registerDuty(slot, subnet_id, validator_index, isAggregator)
