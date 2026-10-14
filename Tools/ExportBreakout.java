// Static analysis only: disassemble a selected, already imported 2 KiB ROM.
// The cartridge is never executed. Output belongs under ignored Library/Research.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class ExportBreakout extends GhidraScript {
    @Override public void run() throws Exception {
        // ROM vectors select $F237; 2 KiB cartridge mirrors are normalized to $F000.
        disassemble(toAddr(0xf237));
        // Static control flow reaches this code via computed return addresses.
        disassemble(toAddr(0xf000));
        disassemble(toAddr(0xf1c6));
        disassemble(toAddr(0xf003));
        disassemble(toAddr(0xf03b));
        disassemble(toAddr(0xf1e1));
        disassemble(toAddr(0xf1f2));
        // BRK is used as a one-byte call to $F1C6. Its padding byte is skipped by RTI.
        for (int pass = 0; pass < 10; pass++) {
            InstructionIterator scan = currentProgram.getListing().getInstructions(true);
            while (scan.hasNext()) {
                Instruction instruction = scan.next();
                if (instruction.getMnemonicString().equals("BRK"))
                    disassemble(instruction.getAddress().add(2));
            }
        }
        // The complete selected image has three referenced data ranges and five
        // padding bytes. Fail rather than silently delivering a partial listing.
        Set<Long> classified = new HashSet<>();
        long[][] data = {{0xf0fe, 0xf132}, {0xf200, 0xf237}, {0xf782, 0xf800}};
        for (long[] range : data)
            for (long address = range[0]; address < range[1]; address++) classified.add(address);
        for (long address : new long[]{0xf255, 0xf25a, 0xf59b, 0xf5a6, 0xf5f9}) classified.add(address);
        InstructionIterator coverage = currentProgram.getListing().getInstructions(true);
        while (coverage.hasNext()) {
            Instruction instruction = coverage.next();
            long start = instruction.getAddress().getOffset();
            for (int i = 0; i < instruction.getLength(); i++)
                if (!classified.add(start + i)) throw new IllegalStateException("Instruction/data overlap at " + Long.toHexString(start + i));
        }
        for (long address = 0xf000; address < 0xf800; address++)
            if (!classified.contains(address)) throw new IllegalStateException("Unclassified byte at " + Long.toHexString(address));
        String[] args = getScriptArgs();
        try (PrintWriter writer = new PrintWriter(args[0])) {
            writer.println("Static Ghidra 6502 disassembly; normalized ROM base $F000; no execution.");
            InstructionIterator instructions = currentProgram.getListing().getInstructions(true);
            while (instructions.hasNext()) {
                Instruction instruction = instructions.next();
                byte[] bytes = instruction.getBytes();
                StringBuilder hex = new StringBuilder();
                for (byte value : bytes) hex.append(String.format("%02x ", value & 255));
                writer.printf("%s %-10s %s%n", instruction.getAddress(), hex, instruction);
            }
        }
    }
}
