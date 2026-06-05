#!/usr/bin/env python3
"""Parse SignalTap CSV for memory_arbiter_bist_single_top debug."""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "output_files/memory_arbiter_w_sdram_single.csv"
with open(path, newline="") as f:
    lines = f.readlines()

hdr = None
data_start = 0
for i, line in enumerate(lines):
    if line.startswith("time unit:"):
        hdr = [x.strip() for x in line.strip().split(",")]
        data_start = i + 1
        break

if hdr is None:
    raise SystemExit("no header")

idx = {n: i for i, n in enumerate(hdr)}


def g(row, name):
    return row[idx[name]] if name in idx else "?"


rows = []
for line in lines[data_start:]:
    line = line.strip()
    if not line or line[0] not in "0123456789":
        continue
    parts = [p.strip() for p in line.split(",")]
    rows.append(parts)

print(f"rows={len(rows)} cols={len(hdr)}")

keys = [
    "fail_latched",
    "start_event",
    "state.S_IDLE",
    "state.S_WR_REQ",
    "state.S_WR_WAIT",
    "state.S_RD_REQ",
    "state.S_RD_DV_WAIT",
    "wait_counter[23..0]",
    "curr_addr[23..0]",
    "client_mem_req",
    "memory_arbiter:mem_arbiter_inst|client_mem_grant[0]",
    "memory_arbiter:mem_arbiter_inst|master_mem_ready",
    "memory_arbiter:mem_arbiter_inst|master_mem_req",
    "memory_arbiter:mem_arbiter_inst|request_in_progress",
    "memory_arbiter:mem_arbiter_inst|grant_cooldown",
    "memory_arbiter:mem_arbiter_inst|read_pending",
    "memory_arbiter:mem_arbiter_inst|active_is_write",
    "start_armed",
    "btn_start",
]

grant = ready = rip_samples = mreq_samples = 0
for r in rows:
    if g(r, "memory_arbiter:mem_arbiter_inst|client_mem_grant[0]") == "1":
        grant += 1
    if g(r, "memory_arbiter:mem_arbiter_inst|master_mem_ready") == "1":
        ready += 1
    if g(r, "memory_arbiter:mem_arbiter_inst|request_in_progress") == "1":
        rip_samples += 1
    if g(r, "memory_arbiter:mem_arbiter_inst|master_mem_req") == "1":
        mreq_samples += 1

print(f"grant=1:{grant} ready=1:{ready} rip=1:{rip_samples} mreq=1:{mreq_samples}")

for r in rows:
    if g(r, "fail_latched") == "1":
        print("FAIL sample t=" + r[0])
        for k in keys:
            print(f"  {k}={g(r, k)}")
        break

se = [r[0] for r in rows if g(r, "start_event") == "1"]
print(f"start_event count={len(se)} times={se[:5]}")

for r in rows:
    if g(r, "state.S_WR_WAIT") == "1":
        print(
            "first S_WR_WAIT t="
            + r[0]
            + f" wait={g(r, 'wait_counter[23..0]')}"
            + f" rip={g(r, 'memory_arbiter:mem_arbiter_inst|request_in_progress')}"
            + f" ready={g(r, 'memory_arbiter:mem_arbiter_inst|master_mem_ready')}"
            + f" grant={g(r, 'memory_arbiter:mem_arbiter_inst|client_mem_grant[0]')}"
            + f" mreq={g(r, 'memory_arbiter:mem_arbiter_inst|master_mem_req')}"
        )
        break

mx = 0
mxt = None
for r in rows:
    if g(r, "state.S_WR_WAIT") == "1":
        w = int(g(r, "wait_counter[23..0]"), 16)
        if w > mx:
            mx = w
            mxt = r[0]
print(f"max WR_WAIT counter={mx} (0x{mx:X}) at t={mxt}")

prev = None
print("--- state timeline ---")
for r in rows:
    st = (
        ("I" if g(r, "state.S_IDLE") == "1" else "")
        + ("wR" if g(r, "state.S_WR_REQ") == "1" else "")
        + ("wW" if g(r, "state.S_WR_WAIT") == "1" else "")
        + ("rR" if g(r, "state.S_RD_REQ") == "1" else "")
        + ("rW" if g(r, "state.S_RD_WAIT") == "1" else "")
        + ("dV" if g(r, "state.S_RD_DV_WAIT") == "1" else "")
    )
    if st != prev:
        print(
            f"t={int(r[0]):>6} state={st or '?'} fail={g(r, 'fail_latched')}"
            f" creq={g(r, 'client_mem_req')}"
            f" rip={g(r, 'memory_arbiter:mem_arbiter_inst|request_in_progress')}"
            f" mreq={g(r, 'memory_arbiter:mem_arbiter_inst|master_mem_req')}"
            f" ready={g(r, 'memory_arbiter:mem_arbiter_inst|master_mem_ready')}"
            f" grant={g(r, 'memory_arbiter:mem_arbiter_inst|client_mem_grant[0]')}"
            f" gcd={g(r, 'memory_arbiter:mem_arbiter_inst|grant_cooldown')}"
            f" wait={g(r, 'wait_counter[23..0]')}"
            f" curr={g(r, 'curr_addr[23..0]')}"
            f" armed={g(r, 'start_armed')} se={g(r, 'start_event')}"
        )
        prev = st

rip_no_ready = [
    r[0]
    for r in rows
    if g(r, "memory_arbiter:mem_arbiter_inst|request_in_progress") == "1"
    and g(r, "memory_arbiter:mem_arbiter_inst|master_mem_ready") == "0"
]
print(f"RIP=1 ready=0 samples: {len(rip_no_ready)}")
if rip_no_ready:
    print(f"  first={rip_no_ready[0]} last={rip_no_ready[-1]}")

print("--- SDRAM during early WR_WAIT ---")
for r in rows:
    t = int(r[0])
    if g(r, "state.S_WR_WAIT") != "1":
        continue
    if t <= 16100:
        print(
            f"t={t} cas={g(r, 'sdram_cas_n')} ras={g(r, 'sdram_ras_n')}"
            f" we={g(r, 'sdram_we_n')} cs={g(r, 'sdram_cs_n')}"
            f" cke={g(r, 'sdram_cke')} addr={g(r, 'sdram_addr[12..0]')}"
        )

ADAPTER_STATES = [
    "sdram_arbiter_adapter:sdram_adapter_inst|state.S_IDLE",
    "sdram_arbiter_adapter:sdram_adapter_inst|state.S_WR_SYNC",
    "sdram_arbiter_adapter:sdram_adapter_inst|state.S_WR_ACK_WAIT",
    "sdram_arbiter_adapter:sdram_adapter_inst|state.S_RD_SYNC",
]

def adapter_state(r):
    for s in ADAPTER_STATES:
        if g(r, s) == "1":
            return s.split("|")[-1].replace("state.", "")
    return "?"

print("--- adapter timeline (15900+) ---")
prev_a = None
for r in rows:
    t = int(r[0])
    if t < 15900:
        continue
    ast = adapter_state(r)
    if ast != prev_a:
        print(
            f"t={t} adp={ast} areq={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|arbiter_mem_req')}"
            f" ready={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|arbiter_mem_ready')}"
            f" wused={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|sdram_write_used[15..0]')}"
            f" wfull={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|sdram_write_full')}"
            f" drain={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|wr_drain_counter[11..0]')}"
            f" wreq={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|sdram_write_request')}"
        )
        prev_a = ast

print("--- adapter during BIST WR_WAIT ---")
for r in rows:
    t = int(r[0])
    if g(r, "state.S_WR_WAIT") != "1":
        continue
    if t <= 16100 or t >= 17900:
        print(
            f"t={t} adp={adapter_state(r)}"
            f" drain={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|wr_drain_counter[11..0]')}"
            f" wused={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|sdram_write_used[15..0]')}"
            f" aready={g(r, 'sdram_arbiter_adapter:sdram_adapter_inst|arbiter_mem_ready')}"
        )

print("--- post-fail tail ---")
for r in rows:
    t = int(r[0])
    if t >= 17940:
        print(
            f"t={t} state_idle={g(r, 'state.S_IDLE')} fail={g(r, 'fail_latched')}"
            f" wr_wait={g(r, 'state.S_WR_WAIT')} rip={g(r, 'memory_arbiter:mem_arbiter_inst|request_in_progress')}"
            f" ready={g(r, 'memory_arbiter:mem_arbiter_inst|master_mem_ready')}"
            f" grant={g(r, 'memory_arbiter:mem_arbiter_inst|client_mem_grant[0]')}"
        )
