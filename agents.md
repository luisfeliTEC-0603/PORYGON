# Agent Guidelines — PORYGON / CE4301

## Authority and references

- Follow this precedence: user instructions > `docs/EnunciadoArqui.md` >
  `docs/isa.md`. These guidelines operationalize the user's instructions.
- Read `docs/EnunciadoArqui.md` for project requirements and `docs/isa.md`
  for the ISA contract. Treat `docs/GUIA.md` and issues as supporting material;
  never let them override either reference.
- Use `docs/isa.md` as the working ISA document. Do not maintain divergent copies.
- Report contradictions with their locations. Do not invent architectural
  decisions to resolve ambiguities or change the ISA contract independently.

## Authorization and scope

- Before generating code or creating, editing, renaming, moving, or overwriting
  files, present a brief plan identifying the files and changes. Wait for the
  user's explicit "OK". Proceed within an already approved scope without asking
  for the same approval again.
- If the scope must expand, present the additional work and wait for approval.
- Read-only inspection is allowed when preparing a proposal.
- Do not execute terminal commands, run simulators, or create auxiliary test
  scripts unless the user expressly requests those actions. Approval to edit
  files does not authorize them.
- Never create commits. Leave versioning and Git operations that modify the
  repository to the user.
- Do not publish or modify issues, comments, or pull requests without an
  explicit instruction.
- Preserve the existing structure. Avoid exhaustive audits, redesigns,
  unnecessary abstractions, and implementation outside the approved task.

## Simulation-only project

- Treat this project as 100% simulation-based. Evaluation uses Icarus Verilog
  or Verilator; FPGA deployment and synthesis are not required.
- Do not add FPGA constraints, vendor IP, synthesis flows, resource-mapping
  requirements, or physical timing closure work unless explicitly requested.
- Model clocked state, combinational behavior, and pipeline timing precisely.
  Simulation-only scope does not permit accidental storage or incomplete logic.
- Model required instruction/data memories explicitly. Behavioral arrays and
  `$readmemh` initialization are appropriate in intentional simulation memory
  models with documented size, ports, access timing, and initialization behavior.
- Do not require a behavioral array to map to a particular physical resource.
  The prohibition on accidental RAM does not prohibit the required memory models.
- Keep stimulus, clock generation, delays, and simulation control in testbenches.
  Keep model-specific memory initialization within the explicit memory model
  or its testbench initialization flow.

## Code quality and organization

- Produce clean, concise, easily navigable files.
- Explain why non-obvious logic exists: constraints, timing, edge cases, and
  key-vault isolation. Do not narrate obvious statements.
- Avoid decorative banners, empty sections, commented-out code, redundant
  explanations, and unnecessary blank lines.
- Organize modules as interface, local types/constants, internal signals,
  logic, and instances. Add section comments only where useful.
- Keep one primary module per file and match the module and file names.
- Keep RTL in `hardware/src/`, testbenches in `hardware/tb/`, software tools
  in `tools/`, and documentation in `docs/`.

## SystemVerilog standards

- Use `logic` for procedural signals. Declare port directions, types, and widths
  explicitly.
- Use `always_comb` with blocking assignments (`=`) for combinational logic.
  Assign every output and temporary on every path. Establish defaults inside
  the block and override them as appropriate.
- Use `always_ff` with nonblocking assignments (`<=`) for sequential state.
  Follow the interface's specified clock, reset, and enable behavior.
- Use `assign` for simple combinational expressions and connections.
- Give each signal a single driver. Do not mix continuous and procedural drivers
  for the same signal.
- Never infer latches, including in simulation models. Do not use `always_latch`
  or combinational feedback to retain values.
- Never introduce accidental RAM or hidden storage. Make all intended state
  and memory explicit, with documented purpose, dimensions, and access behavior.
- Cover decoding and FSM cases with defined behavior. Do not use `casex` or
  X assignments to hide incomplete logic or missing specifications.
- Make signedness, extensions, truncations, and constant widths explicit.
  Do not rely on implicit conversions for arithmetic semantics.
- Centralize shared constants and types in `pkg_vliw.sv`. Use `parameter` for
  configuration and `localparam` for internal or derived constants.
- Use `typedef enum logic` for states and selectors. Use `struct packed` when
  it clarifies existing interfaces without unnecessary complexity.

## Naming, ports, and instantiation

- Use descriptive English names and `snake_case` for files, modules, signals,
  and functions.
- Use `UPPER_SNAKE_CASE` for constants, parameters, and enumeration members.
  End type names with `_t`.
- Use `_i` for inputs and `_o` for outputs. Mark active-low signals with `_n`
  before the direction suffix, for example `rst_ni`.
- Use `_q` for registered state and `_d` for next-state values when explicitly
  separating them. Do not change reset semantics to fit a naming convention.
- Name instances `u_<function>`.
- Connect parameters and ports explicitly by name, one connection per line.
  Do not use positional connections or `.*`.
- Order ports by clock/reset, control, and data. Make unused outputs explicit
  and explain intentional disconnections when not obvious.
- Use four spaces and no tabs in SystemVerilog and Python. Preserve required
  recipe tabs in Makefiles.

## Architectural constraints

- Respect the ISA's 64-bit bundle, four 16-bit slots, and flexible assignment
  of instructions to functional units.
- Distinguish instruction slots, immediate literals, and NOPs. Never dispatch
  a slot consumed as an immediate literal as an instruction.
- Keep data-hazard scheduling in software. Do not add automatic forwarding,
  scoreboarding, or hardware stalls for data dependencies.
- Document and justify any permitted structural stalls.
- Keep `r0` at zero and ignore writes to it as specified by the ISA.
- Use the specification's Feistel4 reference:
  `F(x,k) = (ROL32(x,5) + k) XOR ROL32(x,13)`, with addition modulo 2^32.
- Never expose stored vault keys through general-purpose register or general
  memory reads. Enforce the specified authentication and access-error behavior.
- Do not settle unspecified latencies, arbitration, branch policies, or
  ambiguous encodings without a documented, approved decision.

## Verification and handoff

- Review widths, connections, complete assignments, and consistency with the
  authoritative documents before presenting changes.
- When the user requests test execution, use the project's testbenches and
  simulation workflow within the authorized scope.
- Do not claim that functional simulation alone proves the absence of latches
  or accidental RAM. Do not add synthesis checks solely for that purpose in
  this simulation-only project without an explicit request.
- Report what changed, what was actually checked, and what remains pending.
  Never claim compilation or simulation results that were not obtained.
