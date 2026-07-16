# Hopper Disassembler Python script — export all procedures as pseudo-code
# Run via: hopper -e <binary> -a -o -A ... wait, need analysis then -Y this script
# hopper -l Mach-O --aarch64 -e BIN -a -o -Y this_script.py
#
# Doc: uses Document / Procedure APIs available in Hopper 5.x

import os

out_dir = os.environ.get(
    "NDM_HOPPER_OUT",
    os.path.expanduser("~/NDM/reverse/dumps/hopper_decompile"),
)
os.makedirs(out_dir, exist_ok=True)

doc = Document.getCurrentDocument()
seg_count = doc.getSegmentCount()

index_lines = []
total = 0

for si in range(seg_count):
    seg = doc.getSegment(si)
    name = seg.getName()
    # only code-ish segments
    proc_count = seg.getProcedureCount()
    index_lines.append("# Segment %s procedures=%d" % (name, proc_count))
    for pi in range(proc_count):
        try:
            proc = seg.getProcedureAtIndex(pi)
        except Exception:
            continue
        if proc is None:
            continue
        try:
            addr = proc.getEntryPoint()
            # Hopper uses Address objects; stringify
            addr_s = str(addr)
            try:
                label = proc.getName() or ("sub_%s" % addr_s)
            except Exception:
                label = "sub_%s" % addr_s
            # decompile / pseudo code
            try:
                pseudo = proc.decompile()
            except Exception:
                try:
                    # older API
                    pseudo = doc.decompileProcedure(proc)
                except Exception as e:
                    pseudo = "// decompile failed: %s\n" % e
            safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in label)[:120]
            fname = "%s__%s.c" % (safe, addr_s.replace(" ", "_"))
            path = os.path.join(out_dir, fname)
            with open(path, "w") as f:
                f.write("/* %s @ %s segment=%s */\n" % (label, addr_s, name))
                f.write(pseudo if pseudo else "// empty\n")
            index_lines.append("%s\t%s\t%s" % (addr_s, label, fname))
            total += 1
        except Exception as e:
            index_lines.append("ERR %s" % e)

with open(os.path.join(out_dir, "INDEX.txt"), "w") as f:
    f.write("total_procedures_exported=%d\n" % total)
    f.write("\n".join(index_lines))
    f.write("\n")

print("Exported %d procedures to %s" % (total, out_dir))
doc.close(False)
# quit hopper
import sys
sys.exit(0)
