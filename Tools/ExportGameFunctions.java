// Static Ghidra headless research. Does not execute the imported target.
// @category GameHub.Research
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;

public class ExportGameFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        int firstAddress = 1;
        if (args.length > 1 && args[1].startsWith("sha256:")) {
            if (!args[1].substring(7).equalsIgnoreCase(currentProgram.getExecutableSHA256())) {
                throw new IllegalArgumentException("Ghidra database identity does not match the requested binary SHA-256");
            }
            firstAddress = 2;
        }
        Path directory = Path.of(args[0]);
        Files.createDirectories(directory);
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) {
                throw new IllegalStateException(decompiler.getLastMessage());
            }
            StringBuilder index = new StringBuilder();
            index.append("Ghidra static analysis, decompiler pseudocode (not original source)\n");
            index.append("Program: ").append(currentProgram.getName()).append("\n");
            index.append("SHA-256: ").append(currentProgram.getExecutableSHA256()).append("\n");
            index.append("Language: ").append(currentProgram.getLanguageID()).append("\n");
            index.append("Compiler: ").append(currentProgram.getCompilerSpec().getCompilerSpecID()).append("\n");
            for (int i = firstAddress; i < args.length; i++) {
                Address address = currentProgram.getAddressFactory().getDefaultAddressSpace()
                    .getAddress(args[i].replace("0x", ""));
                Function function = getFunctionAt(address);
                if (function == null) {
                    index.append(args[i]).append(" NO_FUNCTION\n");
                    continue;
                }
                DecompileResults results = decompiler.decompileFunction(function, 60, monitor);
                String filename = "function-" + args[i] + ".c.txt";
                StringBuilder text = new StringBuilder();
                text.append("// Program: ").append(currentProgram.getName()).append("\n");
                text.append("// SHA-256: ").append(currentProgram.getExecutableSHA256()).append("\n");
                text.append("// Entry: ").append(address).append("\n");
                text.append("// Function: ").append(function.getName(true)).append("\n");
                text.append("// Body: ").append(function.getBody()).append("\n");
                text.append("// Signature: ").append(function.getSignature()).append("\n");
                text.append("// Decompiler error: ").append(results.getErrorMessage()).append("\n\n");
                if (results.decompileCompleted() && results.getDecompiledFunction() != null) {
                    text.append(results.getDecompiledFunction().getC());
                }
                Files.writeString(directory.resolve(filename), text, StandardCharsets.UTF_8);
                StringBuilder assembly = new StringBuilder();
                InstructionIterator instructions = currentProgram.getListing()
                    .getInstructions(function.getBody(), true);
                while (instructions.hasNext()) {
                    Instruction instruction = instructions.next();
                    assembly.append(instruction.getAddress()).append(" ")
                        .append(instruction).append("\n");
                    for (Reference reference : instruction.getReferencesFrom()) {
                        Address destination = reference.getToAddress();
                        if (!reference.getReferenceType().isData() || !destination.isMemoryAddress()) continue;
                        try {
                            byte[] bytes = new byte[32];
                            int count = currentProgram.getMemory().getBytes(destination, bytes);
                            assembly.append("  data ").append(destination).append(" ");
                            for (int k = 0; k < count; k++) assembly.append(String.format("%02x", bytes[k] & 255));
                            assembly.append("\n");
                        } catch (Exception ignored) {
                            assembly.append("  data ").append(destination).append(" unavailable\n");
                        }
                    }
                }
                Files.writeString(directory.resolve("function-" + args[i] + ".asm.txt"), assembly, StandardCharsets.UTF_8);
                index.append(args[i]).append(" ").append(function.getName(true)).append(" ")
                    .append(filename).append(" completed=").append(results.decompileCompleted()).append("\n");
                println(args[i] + " " + function.getName(true) + " completed=" + results.decompileCompleted());
            }
            Files.writeString(directory.resolve("index.txt"), index, StandardCharsets.UTF_8);
        } finally {
            decompiler.dispose();
        }
    }
}
