// Offline static research; imported code is never executed.
// @category GameHub.Research
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import java.nio.file.Files;
import java.nio.file.Path;

public class ExportAsteroids extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3 || !args[1].startsWith("sha256:") ||
            !args[1].substring(7).equalsIgnoreCase(currentProgram.getExecutableSHA256())) {
            throw new IllegalArgumentException("Static input SHA-256 must match the imported program");
        }
        if (!currentProgram.getLanguageID().toString().equals("6502:LE:16:default")) {
            throw new IllegalArgumentException("Expected the 6502 language profile");
        }
        for (int i = 2; i < args.length; i++) {
            Address entry = toAddr(args[i]);
            disassemble(entry);
            if (getFunctionAt(entry) == null) createFunction(entry, null);
        }
        analyzeChanges(currentProgram);
        Path output = Path.of(args[0]);
        Files.createDirectories(output);
        StringBuilder assembly = new StringBuilder();
        for (Instruction instruction : currentProgram.getListing().getInstructions(true)) {
            assembly.append(instruction.getAddress()).append(" ").append(instruction).append("\n");
        }
        Files.writeString(output.resolve("all.asm.txt"), assembly.toString());
        StringBuilder index = new StringBuilder();
        index.append("Static decompiler pseudocode, not original source or runtime observation\n");
        index.append("SHA-256: ").append(currentProgram.getExecutableSHA256()).append("\n");
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException(decompiler.getLastMessage());
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                DecompileResults result = decompiler.decompileFunction(function, 10, monitor);
                index.append(function.getEntryPoint()).append(" ").append(function.getBody())
                    .append(" completed=").append(result.decompileCompleted()).append("\n");
                if (result.decompileCompleted() && result.getDecompiledFunction() != null) {
                    Files.writeString(output.resolve("function-" + function.getEntryPoint() + ".txt"),
                                      result.getDecompiledFunction().getC());
                }
            }
            Files.writeString(output.resolve("functions.txt"), index.toString());
        } finally {
            decompiler.dispose();
        }
    }
}
