# Ghidra headless post-script: decompile every function to C-like text
# @category NDM
# @runtime Jython

from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor
import os

out_root = os.environ.get(
    "NDM_GHIDRA_OUT",
    "/Users/gaoyuan/NDM/reverse/dumps/full_decompile/ghidra_c",
)
if not os.path.isdir(out_root):
    os.makedirs(out_root)

program = currentProgram
listing = program.getListing()
fm = program.getFunctionManager()
monitor = ConsoleTaskMonitor()

ifc = DecompInterface()
ifc.openProgram(program)

index_path = os.path.join(out_root, "INDEX.tsv")
index_f = open(index_path, "w")
index_f.write("address\tname\tfile\tsize\tsuccess\n")

count = 0
ok = 0
fail = 0

funcs = fm.getFunctions(True)
for func in funcs:
    count += 1
    name = func.getName()
    entry = func.getEntryPoint()
    addr_s = "0x%X" % entry.getOffset()
    safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in name)[:100]
    fname = "%s__%s.c" % (safe, addr_s)
    path = os.path.join(out_root, fname)

    results = ifc.decompileFunction(func, 60, monitor)
    success = results is not None and results.decompileCompleted()
    body = ""
    if success:
        try:
            body = results.getDecompiledFunction().getC()
            ok += 1
        except Exception as e:
            body = "// decompile completed but getC failed: %s\n" % e
            success = False
            fail += 1
    else:
        fail += 1
        err = ""
        try:
            err = str(results.getErrorMessage())
        except Exception:
            err = "unknown"
        body = "// DECOMPILE FAILED: %s\n" % err
        # still dump disassembly fallback via listing
        try:
            insts = listing.getInstructions(func.getBody(), True)
            lines = ["// fallback disassembly for %s\n" % name]
            while insts.hasNext() and len(lines) < 5000:
                ins = insts.next()
                lines.append("%s  %s\n" % (ins.getAddress(), ins.toString()))
            body += "".join(lines)
        except Exception as e2:
            body += "// disasm fallback failed: %s\n" % e2

    with open(path, "w") as f:
        f.write("/* function %s @ %s */\n" % (name, addr_s))
        f.write(body if body else "// empty\n")

    index_f.write("%s\t%s\t%s\t%d\t%s\n" % (
        addr_s, name, fname, func.getBody().getNumAddresses(), "1" if success else "0"
    ))
    if count % 100 == 0:
        print("progress %d ok=%d fail=%d" % (count, ok, fail))

index_f.close()
summary = "total=%d ok=%d fail=%d out=%s\n" % (count, ok, fail, out_root)
with open(os.path.join(out_root, "SUMMARY.txt"), "w") as f:
    f.write(summary)
print(summary)
