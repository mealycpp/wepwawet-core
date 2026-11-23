"""
gem5 configuration for the WEPWAWET-CORE driver replay (ARM, syscall-emulation mode).

    build/ARM/gem5.opt --outdir=OUT wcore_gem5/gem5/wcore_se.py \
        --binary wcore_gem5/gem5/build/wcore_replay_sign_stage8 --mmio-latency 100ns

What is simulated: one ARM core, private L1 and L2 caches, DDR4 memory, and the
replay program's instruction and memory behaviour.

What stands in for the FPGA: gem5's generic IsaFake device at each WEPWAWET
address. It answers every access after --mmio-latency and returns a constant.
It does not compute anything and has no kernel timing. The latency is a model
PARAMETER (no AXI-Lite round-trip measurement was supplied).

Address map (from the handoff package): host scratchpad interface 0xA0040000,
sequencer GPIO 0xA0030000, descriptor GPIO 0xA0050000, TRNG 0xA0000000,
distributor 0xA0020000, collector 0xA0010000, NTT 0x80030000, INTT 0x80020000,
PolyMulAcc 0x80040000, SHAKE128 0x80050000, SHAKE256 0x80070000.
"""

import argparse

from m5.objects import IsaFake

from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.classic.private_l1_private_l2_cache_hierarchy import (
    PrivateL1PrivateL2CacheHierarchy,
)
from gem5.components.memory import SingleChannelDDR4_2400
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.resources.resource import BinaryResource
from gem5.simulate.simulator import Simulator
from gem5.utils.requires import requires

DEVICES = {
    "wcore_host": 0xA0040000,
    "wcore_seq_gpio": 0xA0030000,
    "wcore_desc_gpio": 0xA0050000,
    "wcore_trng": 0xA0000000,
    "wcore_distributor": 0xA0020000,
    "wcore_collector": 0xA0010000,
    "wcore_ntt": 0x80030000,
    "wcore_intt": 0x80020000,
    "wcore_polymulacc": 0x80040000,
    "wcore_shake128": 0x80050000,
    "wcore_shake256": 0x80070000,
}
DEVICE_SIZE = 0x1000

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
parser.add_argument("--mmio-latency", default="100ns", help="response latency of every WEPWAWET register access")
parser.add_argument("--cpu", default="timing", choices=["timing", "o3"])
parser.add_argument("--clk", default="1.2GHz")
parser.add_argument("--l1", default="32KiB")
parser.add_argument("--l2", default="1MiB")
parser.add_argument("--dump-ticks", type=int, default=0, help="if > 0, dump and reset statistics every this many ticks")
args = parser.parse_args()

requires(isa_required=ISA.ARM)

cache_hierarchy = PrivateL1PrivateL2CacheHierarchy(l1d_size=args.l1, l1i_size=args.l1, l2_size=args.l2)
memory = SingleChannelDDR4_2400(size="64MiB")
processor = SimpleProcessor(
    cpu_type={"timing": CPUTypes.TIMING, "o3": CPUTypes.O3}[args.cpu],
    isa=ISA.ARM,
    num_cores=1,
    clk_freq=args.clk,
)
board = SimpleBoard(clk_freq=args.clk, processor=processor, memory=memory, cache_hierarchy=cache_hierarchy)

# Stand-in register blocks on the memory bus.
for name, base in DEVICES.items():
    device = IsaFake(pio_addr=base, pio_size=DEVICE_SIZE, pio_latency=args.mmio_latency, ret_data32=0)
    setattr(board, name, device)
    device.pio = cache_hierarchy.membus.mem_side_ports

board.set_se_binary_workload(BinaryResource(local_path=args.binary))

simulator = Simulator(board=board)
simulator._instantiate()

# Map each register block into the program's address space, uncacheable, at its physical address.
process = board.get_processor().get_cores()[0].core.workload[0]
for base in DEVICES.values():
    process.map(base, base, DEVICE_SIZE, False)

if args.dump_ticks > 0:
    import m5

    m5.stats.periodicStatDump(args.dump_ticks)

simulator.run()
print("exit cause:", simulator.get_last_exit_event_cause())
