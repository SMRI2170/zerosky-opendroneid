# Circom Optimization Comparison Report

## Overview

This document summarizes how the Circom compiler optimization levels `--O0`, `--O1`, and `--O2` affect the circuit:

- `circuits/distance_30m_time.circom`

The comparison was run with the helper script:

- `scripts/compare_circom_optimizations.sh`

The purpose of this comparison is to understand:

1. How much the compiled circuit changes depending on optimization level
2. Which metrics actually improve
3. What those changes mean for proof-system cost and circuit structure
4. Where the main complexity of this circuit really comes from

## Environment

- `circom 2.2.2`
- `snarkjs 0.7.5`
- Prime field: `bn128`

## Circuit Under Test

The circuit proves whether:

- the 3D distance between drone and target is within `30m`
- the time difference is within `5 seconds`

The main structure is:

1. Compute absolute differences for latitude, longitude, altitude, and time
2. Convert latitude/longitude deltas into scaled centimeter-space values
3. Compute squared distance
4. Compare squared distance against the threshold
5. Compare time difference against the threshold
6. Output:
   - `within30`
   - `distance_ok`
   - `time_ok`

The key templates are:

- `Num2Bits(n)`
- `LessThan(n)`
- `LessEqThan(n)`
- `AbsDiff(n)`
- `Distance30mTimeWindow(...)`

## Method

For each optimization level:

- compile with `circom`
- emit `r1cs`, `wasm`, `sym`
- emit simplification substitutions JSON
- inspect the result with `snarkjs r1cs info`

Command pattern used:

```bash
circom circuits/distance_30m_time.circom \
  --O0|--O1|--O2 \
  --r1cs \
  --wasm \
  --sym \
  --inspect \
  --simplification_substitution \
  -o <output_dir>
```

Then:

```bash
snarkjs r1cs info <output_dir>/distance_30m_time.r1cs
```

## Raw Results

Source:

- `zk-distance/optimization-compare/summary.csv`

| Optimization | Constraints | Wires | Private Inputs | Public Inputs | Public Outputs | Labels | R1CS Bytes | WASM Bytes | SYM Bytes | Substitutions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `O0` | 609 | 608 | 8 | 0 | 3 | 608 | 95,444 | 47,068 | 23,989 | 0 |
| `O1` | 574 | 573 | 8 | 0 | 3 | 608 | 92,152 | 46,928 | 23,954 | 35 |
| `O2` | 534 | 533 | 8 | 0 | 3 | 608 | 106,472 | 46,768 | 23,914 | 75 |

## Relative Change vs `O0`

| Optimization | Constraint Change | Wire Change | R1CS Size Change | WASM Size Change | SYM Size Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| `O1` | `-5.75%` | `-5.76%` | `-3.45%` | `-0.30%` | `-0.15%` |
| `O2` | `-12.32%` | `-12.34%` | `+11.55%` | `-0.64%` | `-0.31%` |

## Meaning of Each Metric

### Constraints

This is the most important structural cost metric.

- Fewer constraints usually means a cheaper proving workload
- Constraint count is one of the clearest indicators of circuit heaviness

In this circuit:

- `O0`: `609`
- `O1`: `574`
- `O2`: `534`

So optimization is clearly working, especially at `O2`.

### Wires

This is the number of signals/wires in the compiled R1CS.

- Fewer wires usually indicates that intermediate signals were simplified away
- Wire count often tracks with simplification quality

In this circuit:

- `O0`: `608`
- `O1`: `573`
- `O2`: `533`

This shows that the optimizer is eliminating intermediate structure.

### Substitutions

This measures how many signal substitutions were recorded during simplification.

Interpretation:

- a signal does not need to remain independent
- the compiler can replace it with another signal or linear expression
- more substitutions generally means more successful simplification

Observed values:

- `O0`: `0`
- `O1`: `35`
- `O2`: `75`

This is consistent with the reduction in constraints and wires.

### Labels

The number of labels stayed constant:

- `608` for all modes

This is not surprising. Labels reflect symbolic naming and source-level structure more than the final optimized constraint system.

### R1CS / WASM / SYM file sizes

These are useful secondary metrics, but they are not as trustworthy as `constraints` and `wires` for proof-cost interpretation.

- `WASM` and `SYM` decrease slightly with optimization
- `R1CS` size behaves differently and actually increases at `O2`

This means:

- file size alone is not a reliable proxy for proving cost
- structural metrics should be prioritized over byte size

## What Changed Between `O0`, `O1`, and `O2`

## `O0`

`O0` is the unsimplified baseline.

Characteristics:

- no simplification substitutions
- the circuit remains close to the explicit source structure
- most intermediate signals survive into the compiled system

This mode is useful for:

- understanding the raw circuit structure
- debugging circuit shape
- comparing optimization impact from a clean baseline

## `O1`

`O1` is the default, lighter simplification mode.

Observed effect:

- 35 substitutions
- 35 fewer constraints than `O0`
- 35 fewer wires than `O0`

Interpretation:

- basic signal-to-signal and signal-to-constant simplifications are working
- some intermediate expressions are being collapsed
- but not all linear structure has been eliminated

## `O2`

`O2` applies stronger simplification.

Observed effect:

- 75 substitutions
- 75 fewer constraints than `O0`
- 75 fewer wires than `O0`

Interpretation:

- more aggressive linear simplification occurs
- many intermediate linear relationships are absorbed
- the resulting R1CS is materially smaller than both `O0` and `O1`

## Important Structural Observation

During compile logs, the circuit reported:

- at `O0`: `534` non-linear constraints and `75` linear constraints
- at `O1`: `534` non-linear constraints and `40` linear constraints
- at `O2`: `534` non-linear constraints and `0` linear constraints

This is the most important takeaway from the entire comparison.

It means:

- optimization is mostly removing linear constraints
- the non-linear core of the circuit is unchanged
- the real cost center is not the linear arithmetic glue
- the real cost center is the comparison / bit-decomposition logic

## Where the Complexity Comes From

The main expensive part of this circuit is not:

- `lat_scaled`
- `lon_scaled`
- `alt_scaled`
- `lat_sq`
- `lon_sq`
- `alt_sq`
- `distance_scaled_sq`

Those are exactly the kinds of expressions that optimization can often fold, substitute, or compress.

The expensive part is much more likely to be:

- `Num2Bits(n)`
- `LessThan(n)`
- `LessEqThan(n)`

Why:

1. `Num2Bits(n)` forces bit decomposition
2. Each output bit is constrained to be boolean
3. Reconstruction constraints ensure the bits sum back to the original value
4. `LessThan` depends on a widened bit-decomposition of `n + 1`

This circuit uses:

- `AbsDiff(32)` for latitude
- `AbsDiff(32)` for longitude
- `AbsDiff(32)` for altitude
- `AbsDiff(64)` for time
- `LessEqThan(128)` for squared distance comparison
- `LessEqThan(64)` for time comparison

That means the circuit repeatedly invokes bit-heavy comparison logic, and those constraints are fundamentally harder to simplify away.

## What Substitutions Likely Represent in This Circuit

The substitutions do not primarily mean that the comparison circuits disappeared.

Instead, they likely correspond to simplification of intermediate expressions such as:

- `left_term`
- `right_term`
- `lat_scaled`
- `lon_scaled`
- `alt_scaled`
- `lat_sq`
- `lon_sq`
- `alt_sq`
- `distance_scaled_sq`

These are useful in source code for readability, but the optimizer can often inline or merge them.

So:

- substitutions indicate simplification success
- they do not mean the hard comparison logic has become cheap

## Why `O2` Helps But Does Not Change Everything

`O2` helps because it removes linear overhead.

However, `O2` cannot magically remove:

- booleanity constraints on bits
- bit decomposition constraints
- comparison logic that is intrinsically non-linear

So the observed pattern is exactly what we should expect for this kind of circuit:

- moderate improvement in total constraint count
- strong cleanup of linear structure
- no major reduction in the non-linear comparison core

## Why `R1CS` Size Increased at `O2`

This result can look surprising:

- constraints went down
- wires went down
- but `distance_30m_time.r1cs` got larger

This suggests that serialized `r1cs` file size is not a direct measure of circuit proving complexity.

Possible reasons include:

- different encoding structure after simplification
- larger coefficients or different sparse representations
- metadata/layout effects in the serialized format

Conclusion:

- do not use `.r1cs` file size as the primary optimization metric
- use `constraints`, `wires`, and if needed real proving time

## Compiler Warnings Observed

The compiler emitted `CA02` warnings such as:

- some `toBits.out[...]` signals do not appear in any constraint of the father component

This occurred for:

- `LessThan(32)`
- `LessThan(64)`
- `LessThan(128)`

Interpretation:

- the parent component only uses the most significant comparison bit
- the remaining bit outputs are not directly consumed by the parent
- this is expected for this pattern and not automatically a bug

Still, these warnings are useful because they highlight where large internal structures exist but are only partially exposed upward.

## Practical Conclusion

For this circuit:

- `O2` is the best choice among the three tested options
- `O1` helps, but not as much as `O2`
- the improvement is real but not dramatic
- the dominant cost still comes from bit decomposition and comparison templates

In short:

> `O2` successfully removes most linear overhead, but the main proving cost remains in the comparison logic.

## Recommended Interpretation for Future Work

If your goal is:

### Better compiled circuit quality

Use:

- `--O2`

### Understanding raw circuit shape

Use:

- `--O0`

### Fast baseline with some simplification

Use:

- `--O1`

## If You Want to Optimize Further

Changing optimization flags alone will not produce dramatic additional gains beyond `O2`.

The next gains would need to come from circuit design changes, especially around:

- reducing the number of `LessThan` / `LessEqThan` calls
- reducing bit widths where safely possible
- restructuring comparisons
- reconsidering whether full generic `Num2Bits`-based comparisons are needed everywhere

That is where the main cost lives.

## Generated Files

Relevant generated outputs:

- `zk-distance/optimization-compare/O0/`
- `zk-distance/optimization-compare/O1/`
- `zk-distance/optimization-compare/O2/`
- `zk-distance/optimization-compare/summary.csv`

## Reproduction

Run:

```bash
bash scripts/compare_circom_optimizations.sh
```

Artifacts will be written to:

```bash
zk-distance/optimization-compare/
```
