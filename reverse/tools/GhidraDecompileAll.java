//Decompile every function in the current program to C-like text files.
//@category NDM
//@menupath Tools.NDM.DecompileAll

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.util.task.ConsoleTaskMonitor;

public class GhidraDecompileAll extends GhidraScript {

	@Override
	protected void run() throws Exception {
		String outRoot = System.getenv("NDM_GHIDRA_OUT");
		if (outRoot == null || outRoot.isEmpty()) {
			outRoot = "/Users/gaoyuan/NDM/reverse/dumps/full_decompile/ghidra_c";
		}
		File outDir = new File(outRoot);
		if (!outDir.exists() && !outDir.mkdirs()) {
			printerr("cannot create " + outRoot);
			return;
		}

		DecompInterface ifc = new DecompInterface();
		ifc.openProgram(currentProgram);
		ConsoleTaskMonitor monitor = new ConsoleTaskMonitor();
		Listing listing = currentProgram.getListing();

		File indexFile = new File(outDir, "INDEX.tsv");
		PrintWriter index = new PrintWriter(new FileWriter(indexFile));
		index.println("address\tname\tfile\tbytes\tsuccess");

		int count = 0;
		int ok = 0;
		int fail = 0;

		FunctionIterator funcs = currentProgram.getFunctionManager().getFunctions(true);
		while (funcs.hasNext() && !monitor.isCancelled()) {
			Function func = funcs.next();
			count++;
			String name = func.getName();
			String addrS = String.format("0x%X", func.getEntryPoint().getOffset());
			String safe = name.replaceAll("[^A-Za-z0-9._-]", "_");
			if (safe.length() > 100) {
				safe = safe.substring(0, 100);
			}
			String fname = safe + "__" + addrS + ".c";
			File out = new File(outDir, fname);

			DecompileResults results = ifc.decompileFunction(func, 60, monitor);
			boolean success = results != null && results.decompileCompleted();
			String body;
			if (success && results.getDecompiledFunction() != null) {
				body = results.getDecompiledFunction().getC();
				ok++;
			}
			else {
				fail++;
				String err = results == null ? "null" : String.valueOf(results.getErrorMessage());
				StringBuilder sb = new StringBuilder();
				sb.append("// DECOMPILE FAILED: ").append(err).append("\n");
				sb.append("// fallback disassembly\n");
				try {
					InstructionIterator insts = listing.getInstructions(func.getBody(), true);
					int n = 0;
					while (insts.hasNext() && n < 5000) {
						Instruction ins = insts.next();
						sb.append(ins.getAddress()).append("  ").append(ins.toString()).append("\n");
						n++;
					}
				}
				catch (Exception e) {
					sb.append("// disasm fallback failed: ").append(e).append("\n");
				}
				body = sb.toString();
			}

			PrintWriter pw = new PrintWriter(new FileWriter(out));
			pw.println("/* function " + name + " @ " + addrS + " */");
			pw.print(body == null ? "// empty\n" : body);
			pw.close();

			long nbytes = func.getBody().getNumAddresses();
			index.println(addrS + "\t" + name + "\t" + fname + "\t" + nbytes + "\t" + (success ? "1" : "0"));

			if (count % 100 == 0) {
				println("progress " + count + " ok=" + ok + " fail=" + fail);
			}
		}

		index.close();
		PrintWriter sum = new PrintWriter(new FileWriter(new File(outDir, "SUMMARY.txt")));
		String summary = "total=" + count + " ok=" + ok + " fail=" + fail + " out=" + outRoot;
		sum.println(summary);
		sum.close();
		println(summary);
	}
}
