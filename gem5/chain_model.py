#!/usr/bin/env python3
"""
Transaction accounting for three ways of driving the WEPWAWET kernels.

  account_dasc()    A  DASC 2026 shared-DMA host driver. Counts read off
                       reference_from_handoff/wp_hw.py. The register traffic
                       inside the PYNQ DMA driver and all timings are NOT
                       included: they were not supplied.
  account_stage8()  B  Stage 8 as the handoff backend drives it today. The
                       closed form here is checked against a replay of the
                       unmodified backend (tests/test_stage8_replay.py).
  account_chain()   C  PROPOSED autonomous multi-kernel execution with
                       intermediates retained in the FPGA scratchpad. This
                       hardware behaviour does not exist yet; every number it
                       returns is model-predicted.

A "job" is one kernel dispatch as recorded by wcore_model.WcoreModel.jobs or
workload.CallLevelHW.jobs: name, tx (input words), rx (output words).
"""

from collections import OrderedDict

POLY_WORDS = 128
MMIO_PER_WORD_COMMAND = 6       # Stage 8 host interface, from the backend's _write_word/_read_word
STAGE8_CONTROL_MMIO = 16        # per job: descriptor 6, start/ack 4, sequencer status 5, host check 1
SHAKE_CFG_MMIO = 2
PULSE_SLEEP_S = 0.002           # backend._pulse: time.sleep(.002), twice per job
POLL_SLEEP_S = 0.005            # backend job poll loop: time.sleep(.005) per busy poll


def _is_shake(job):
    return job["name"].startswith("shake")


def _zero():
    return dict(kernel_dispatches=0, programs=0, word_cmd_load=0, word_cmd_zero=0, word_cmd_read=0,
                word_cmd_scrub=0, word_commands=0, mmio_control=0, mmio_total=0, bytes_cpu_to_fabric=0,
                bytes_fabric_to_cpu=0, driver_sleeps=0, driver_sleep_seconds=0.0)


def _finish(t, host_busy_polls):
    t["word_commands"] = t["word_cmd_load"] + t["word_cmd_zero"] + t["word_cmd_read"] + t["word_cmd_scrub"]
    t["mmio_total"] = t["word_commands"] * (MMIO_PER_WORD_COMMAND + host_busy_polls) + t["mmio_control"]
    t["bytes_cpu_to_fabric"] = 8 * (t["word_cmd_load"] + t["word_cmd_zero"] + t["word_cmd_scrub"])
    t["bytes_fabric_to_cpu"] = 8 * t["word_cmd_read"]
    t["driver_sleep_seconds"] = round(t["driver_sleep_seconds"], 6)
    return t


def account_stage8(jobs, host_busy_polls=0, job_busy_polls=0):
    """Case B. One job at a time; the CPU loads, zero-initialises, reads and scrubs every word."""
    t = _zero()
    for j in jobs:
        tx, rx = j["tx_words"], j["rx_words"]
        t["kernel_dispatches"] += 1
        t["programs"] += 1
        t["word_cmd_load"] += tx
        t["word_cmd_zero"] += rx
        t["word_cmd_read"] += rx
        t["word_cmd_scrub"] += tx + rx
        t["mmio_control"] += STAGE8_CONTROL_MMIO + (SHAKE_CFG_MMIO if _is_shake(j) else 0) + job_busy_polls
        t["driver_sleeps"] += 2 + job_busy_polls
        t["driver_sleep_seconds"] += 2 * PULSE_SLEEP_S + job_busy_polls * POLL_SLEEP_S
    return _finish(t, host_busy_polls)


def account_dasc(jobs):
    """Case A. Structure only: kernel-IP register writes, DMA API calls and bulk bytes per call."""
    t = dict(kernel_dispatches=0, kernel_ip_mmio_writes=0, dma_transfer_calls=0, dma_wait_calls=0,
             bytes_ddr_to_fabric_by_dma=0, bytes_fabric_to_ddr_by_dma=0)
    for j in jobs:
        t["kernel_dispatches"] += 1
        # _config_route: 4 register writes + 2 start pulses; then the kernel's own start pulse.
        t["kernel_ip_mmio_writes"] += 7 + (SHAKE_CFG_MMIO if _is_shake(j) else 0)
        t["dma_transfer_calls"] += 2
        t["dma_wait_calls"] += 2
        t["bytes_ddr_to_fabric_by_dma"] += 8 * j["tx_words"]
        t["bytes_fabric_to_ddr_by_dma"] += 8 * j["rx_words"]
    return t


def _operands(job):
    """Split a job's input into operands: polynomials for the polynomial kernels, one seed for SHAKE."""
    tx = job["tx"]
    if _is_shake(job):
        return [("seed", job["name"], job["msg_bytes"], tx)]
    return [("poly", tx[i:i + POLY_WORDS]) for i in range(0, len(tx), POLY_WORDS)]


def _slots(words):
    return max(1, -(-words // POLY_WORDS))


class GhostTransfer(AssertionError):
    """An instruction consumed data that was neither loaded by the CPU nor produced in the fabric."""


def account_chain(jobs, slots=16, read_policy="all", max_program=16, mmio_per_instruction=4,
                  mmio_per_program=12, host_busy_polls=0, job_busy_polls=0, failed_jobs=(), plan=None):
    """Case C (HYPOTHETICAL). Kernels run as microcoded programs; operands stay in the scratchpad.

    slots           scratchpad capacity in 128-word polynomial slots (4 banks x 2048 words = 64)
    read_policy     'all'        the CPU reads every kernel output (conservative)
                    'unconsumed' the CPU reads an output only if no later kernel consumes it unchanged
                                 (optimistic lower bound: software may still need some of those values)
    max_program     most instructions in one microcoded program
    A program ends when the next instruction needs data the CPU has not yet loaded, because that
    data may depend on a result the CPU must read first. SHAKE outputs are always read by the CPU.
    failed_jobs     indices of jobs that fail once: the scratchpad is flushed and the job is redone.
    plan            optional list; receives one dict per dispatched job (new_program, load_words,
                    read_words) so that a driver replay can issue exactly the accounted traffic.
    """
    if read_policy not in ("all", "unconsumed"):
        raise ValueError("read_policy must be 'all' or 'unconsumed'")
    t = _zero()
    t.update(operands_loaded=0, operands_reused=0, fabric_to_fabric_edges=0, evictions=0, recoveries=0)
    resident = OrderedDict()            # operand content -> dict(owner, slots, producer)
    used = 0
    later_inputs = {}
    for i, j in enumerate(jobs):
        for op in _operands(j):
            later_inputs[op[-1]] = i     # last job index that consumes this content
    program_len = 0
    failed = set(failed_jobs)

    def make_room(need, pinned):
        nonlocal used
        while used + need > slots:
            victim = next((k for k in resident if k not in pinned), None)
            if victim is None:
                raise ValueError("scratchpad too small for one instruction's operands")
            used -= resident.pop(victim)["slots"]
            t["evictions"] += 1

    i = 0
    while i < len(jobs):
        j = jobs[i]
        ops = _operands(j)
        contents = [op[-1] for op in ops]
        need_load = [c for c in dict.fromkeys(contents) if c not in resident]
        if program_len == 0 or need_load or program_len >= max_program:
            t["programs"] += 1
            t["mmio_control"] += mmio_per_program + job_busy_polls
            t["driver_sleeps"] += 2 + job_busy_polls
            t["driver_sleep_seconds"] += 2 * PULSE_SLEEP_S + job_busy_polls * POLL_SLEEP_S
            program_len = 0
        pinned = set(contents)
        for c in need_load:
            make_room(_slots(len(c)), pinned)
            resident[c] = dict(owner="cpu", slots=_slots(len(c)), producer=None)
            used += resident[c]["slots"]
            t["word_cmd_load"] += len(c)
            t["operands_loaded"] += 1
        for c in contents:
            if c not in resident:
                raise GhostTransfer(f"job {i} ({j['name']}) consumed an operand with no recorded source")
            if c not in need_load:
                t["operands_reused"] += 1
                if resident[c]["owner"] == "kernel":
                    t["fabric_to_fabric_edges"] += 1
            resident.move_to_end(c)
        if i in failed:
            failed.discard(i)
            t["recoveries"] += 1
            resident.clear()             # after a fault nothing in the scratchpad is trusted
            used = 0
            program_len = 0
            continue                     # redo the same job: its operands are loaded again
        t["kernel_dispatches"] += 1
        t["mmio_control"] += mmio_per_instruction + (SHAKE_CFG_MMIO if _is_shake(j) else 0)
        out = j["rx"]
        chained = (not _is_shake(j)) and later_inputs.get(out, -1) > i
        read_words = len(out) if (read_policy == "all" or not chained) else 0
        t["word_cmd_read"] += read_words
        if plan is not None:
            plan.append(dict(job=i, new_program=program_len == 0, load_words=sum(len(c) for c in need_load),
                             read_words=read_words))
        program_len += 1
        if out not in resident:
            make_room(_slots(len(out)), pinned)
            resident[out] = dict(owner="kernel", slots=_slots(len(out)), producer=i)
            used += resident[out]["slots"]
        i += 1
    return _finish(t, host_busy_polls)


def shake_regeneration(jobs):
    """Full-prefix regeneration: bytes produced by SHAKE jobs versus the longest prefix per seed."""
    longest, produced, calls = {}, 0, 0
    for j in jobs:
        if not _is_shake(j):
            continue
        calls += 1
        produced += j["out_bytes"]
        key = (j["name"], j["msg_bytes"], j["tx"])
        longest[key] = max(longest.get(key, 0), j["out_bytes"])
    needed = sum(longest.values())
    return dict(shake_calls=calls, shake_distinct_streams=len(longest), shake_bytes_produced=produced,
                shake_bytes_if_incremental=needed, shake_bytes_regenerated=produced - needed)
