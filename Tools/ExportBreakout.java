// Static analysis only: disassemble a selected, already imported 2 KiB ROM.
// The cartridge is never executed. Output belongs under ignored Library/Research.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import java.io.PrintWriter;

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
