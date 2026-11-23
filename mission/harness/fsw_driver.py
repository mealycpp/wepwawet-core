#!/usr/bin/env python3
"""Rate-controlled F' command driver over ONE persistent GDS connection.

Why not CmdSequencer: in this deployment the LinuxTimer ticks at 1 Hz and cmdSeq.schedIn sits on rateGroup2
(divisor 2) -> timed sequence records are only checked every 2 s, so a sequence cannot pace PeerPing at
1..50 /s (zero-delay records run back-to-back = saturation only). fprime-cli costs ~1 s per call (process
start + dictionary load + connect). This driver reuses fprime-cli's own argument parsing/validation and its
CommandSendCommand.handle_arguments() pipeline setup (same GDS version on the board), but sends N commands on
one IntegrationTestAPI connection.

Must run with the F' venv python from the deployment project dir (dictionary autodetect, like fprime-cli):
  cd $PRJ && python fsw_driver.py --rate 10 --seconds 60 --mode open --out driver.json
mode open  : fixed-rate open loop (send times recorded; lateness counted)
mode closed: send_and_assert_command (waits for completion, timeout 5 s) -> rate = min(R, completion rate)
"""
import argparse, json, os, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('--rate', type=float, required=True)
ap.add_argument('--seconds', type=float, required=True)
ap.add_argument('--mode', choices=['open', 'closed'], default='open')
ap.add_argument('--command', default='WepwawetDeployment.pqcTransport.PeerPing')
ap.add_argument('--out', default='driver.json')
mine, rest = ap.parse_known_args()

from fprime_gds.executables.fprime_cli import create_parser, parse_args   # noqa: E402
import fprime_gds.common.gds_cli.command_send as cs                         # noqa: E402

RESULT = {}


class RatedSend(cs.CommandSendCommand):
    @classmethod
    def _execute_command(cls, args, api):
        period = 1.0 / mine.rate
        sends, late, errors, compl = [], 0, 0, []
        t0 = time.monotonic(); n = 0
        while True:
            target = t0 + n * period
            if target - t0 >= mine.seconds:
                break
            now = time.monotonic()
            if target > now:
                time.sleep(target - now)
            elif now - target > period:
                late += 1
            ts = time.time()
            try:
                if mine.mode == 'closed':
                    api.send_and_assert_command(mine.command, [], timeout=5)
                    compl.append(time.time() - ts)
                else:
                    api.send_command(mine.command, [])
            except Exception as exc:                        # count, keep pacing
                errors += 1
                RESULT.setdefault('first_error', repr(exc))
            sends.append(ts); n += 1
        RESULT.update(command=mine.command, mode=mine.mode, rate_requested=mine.rate, seconds=mine.seconds,
                      sent=len(sends), late_sends=late, send_errors=errors,
                      achieved_rate=(len(sends) / (sends[-1] - sends[0])) if len(sends) > 1 else None,
                      t_first=sends[0] if sends else None, t_last=sends[-1] if sends else None,
                      closed_completion_s=compl or None)


args = parse_args(create_parser(), ['command-send', mine.command] + rest)
if getattr(args, 'zmq', False):
    pass
RatedSend.handle_arguments(args)
json.dump(RESULT, open(mine.out, 'w'), indent=1)
print(json.dumps({k: v for k, v in RESULT.items() if k != 'closed_completion_s'}))
sys.exit(0 if RESULT.get('sent') else 1)
