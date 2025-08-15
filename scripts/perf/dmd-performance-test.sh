#!/bin/bash
# DMD Performance Stress Test Script
# Properly stresses the compiler with meaningful tests
# Usage: ./dmd-stress-test.sh [baseline|pr|compare]

set -euo pipefail

TEST_TYPE="${1:-pr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/stress-test-results"
TEST_RUNS=5  # Number of runs per test for statistical significance
HOST_COMPILER="${HOST_COMPILER:-ldc2}"  # Use LDC as host compiler

mkdir -p "$RESULTS_DIR"

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check for required tools
check_requirements() {
    local missing=()
    
    for tool in "$HOST_COMPILER" bc jq time; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: apt-get install ldc bc jq time"
        exit 1
    fi
    
    log_success "All requirements satisfied"
}

# Calculate median of array
calculate_median() {
    local values=("$@")
    local count=${#values[@]}
    
    # Sort values
    IFS=$'\n' sorted=($(sort -n <<<"${values[*]}"))
    unset IFS
    
    # Calculate median
    if [ $((count % 2)) -eq 0 ]; then
        local mid=$((count / 2))
        local val1=${sorted[$((mid - 1))]}
        local val2=${sorted[$mid]}
        echo "scale=6; ($val1 + $val2) / 2" | bc -l
    else
        local mid=$((count / 2))
        echo "${sorted[$mid]}"
    fi
}

# Calculate standard deviation
calculate_stddev() {
    local values=("$@")
    local count=${#values[@]}
    
    # Calculate mean
    local sum=0
    for val in "${values[@]}"; do
        sum=$(echo "$sum + $val" | bc -l)
    done
    local mean=$(echo "scale=6; $sum / $count" | bc -l)
    
    # Calculate variance
    local var_sum=0
    for val in "${values[@]}"; do
        local diff=$(echo "$val - $mean" | bc -l)
        var_sum=$(echo "$var_sum + ($diff * $diff)" | bc -l)
    done
    local variance=$(echo "scale=6; $var_sum / $count" | bc -l)
    
    # Calculate standard deviation
    echo "scale=6; sqrt($variance)" | bc -l | sed 's/^\./0./'
}

# Time a command accurately (compilation only, no I/O)
time_command() {
    local command="$1"
    local start_ns=$(date +%s%N)
    
    # Run command, discarding output
    eval "$command" >/dev/null 2>&1
    local exit_code=$?
    
    local end_ns=$(date +%s%N)
    
    if [ $exit_code -ne 0 ]; then
        echo "999.999999"
        return 1
    fi
    
    # Convert to seconds with microsecond precision
    echo "scale=6; ($end_ns - $start_ns) / 1000000000" | bc -l | sed 's/^\./0./'
}

# Run stress test with multiple iterations
run_stress_test() {
    local test_name="$1"
    local test_description="$2"
    local setup_command="$3"
    local test_command="$4"
    local timeout_seconds="${5:-600}"
    
    log_info "Running: $test_description"
    log_info "Performing $TEST_RUNS iterations..."
    
    # Setup test files once
    eval "$setup_command"
    
    # Warm-up run (not counted)
    log_info "Warm-up run..."
    timeout "$timeout_seconds" bash -c "$test_command" >/dev/null 2>&1 || true
    
    # Collect timings
    local timings=()
    local failures=0
    
    for i in $(seq 1 $TEST_RUNS); do
        echo -n "  Run $i/$TEST_RUNS: "
        
        local duration=$(timeout "$timeout_seconds" bash -c "time_command '$test_command'" || echo "999.999999")
        
        if [[ "$duration" == "999.999999" ]]; then
            echo "FAILED/TIMEOUT"
            ((failures++))
        else
            echo "${duration}s"
            timings+=("$duration")
        fi
    done
    
    # Calculate statistics if we have successful runs
    if [ ${#timings[@]} -gt 0 ]; then
        local median=$(calculate_median "${timings[@]}")
        local stddev=$(calculate_stddev "${timings[@]}")
        local min=$(printf '%s\n' "${timings[@]}" | sort -n | head -1)
        local max=$(printf '%s\n' "${timings[@]}" | sort -n | tail -1)
        
        log_success "$test_description completed"
        log_info "  Median: ${median}s, StdDev: ${stddev}s"
        log_info "  Min: ${min}s, Max: ${max}s"
        log_info "  Success rate: $((TEST_RUNS - failures))/$TEST_RUNS"
        
        # Save to JSON
        save_test_result "$test_name" "$median" "$stddev" "$min" "$max" "$test_description" "$failures"
    else
        log_error "$test_description failed all iterations"
        save_test_result "$test_name" "999.999999" "0" "999.999999" "999.999999" "$test_description" "$TEST_RUNS"
    fi
    
    # Cleanup
    rm -rf stress_test_*
}

# Initialize JSON results
init_json() {
    cat > "$RESULTS_DIR/results.json" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "test_type": "$TEST_TYPE",
  "host_compiler": "$HOST_COMPILER",
  "test_runs": $TEST_RUNS,
  "host_info": {
    "hostname": "$(hostname)",
    "os": "$(uname -s)",
    "arch": "$(uname -m)",
    "cpu_count": $(nproc),
    "memory_kb": $(grep MemTotal /proc/meminfo | awk '{print $2}')
  },
  "git_info": {
    "commit": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "branch": "$(git branch --show-current 2>/dev/null || echo 'unknown')",
    "dirty": $(git diff --quiet 2>/dev/null && echo 'false' || echo 'true')
  },
  "tests": {}
}
EOF
}

# Save test result to JSON
save_test_result() {
    local name="$1"
    local median="$2"
    local stddev="$3"
    local min="$4"
    local max="$5"
    local description="$6"
    local failures="$7"
    
    local tmpfile=$(mktemp)
    jq --arg name "$name" \
       --arg median "$median" \
       --arg stddev "$stddev" \
       --arg min "$min" \
       --arg max "$max" \
       --arg desc "$description" \
       --arg failures "$failures" \
       '.tests[$name] = {
         "median": ($median | tonumber),
         "stddev": ($stddev | tonumber),
         "min": ($min | tonumber),
         "max": ($max | tonumber),
         "description": $desc,
         "failures": ($failures | tonumber)
       }' "$RESULTS_DIR/results.json" > "$tmpfile"
    mv "$tmpfile" "$RESULTS_DIR/results.json"
}

# Build DMD with LDC
build_dmd() {
    log_info "Building DMD with host compiler: $HOST_COMPILER"
    
    cd "$PROJECT_ROOT"
    
    # Clean previous build
    make -f posix.mak clean >/dev/null 2>&1 || true
    
    # Build with LDC
    if make -f posix.mak -j$(nproc) HOST_DMD="$HOST_COMPILER" ENABLE_RELEASE=1 MODEL=64 >/dev/null 2>&1; then
        log_success "DMD built successfully"
    else
        log_error "Failed to build DMD"
        exit 1
    fi
    
    # Find and verify DMD binary
    DMD_BINARY="$PROJECT_ROOT/generated/linux/release/64/dmd"
    if [ ! -f "$DMD_BINARY" ]; then
        log_error "DMD binary not found at $DMD_BINARY"
        exit 1
    fi
    
    if ! "$DMD_BINARY" --version >/dev/null 2>&1; then
        log_error "DMD binary not functional"
        exit 1
    fi
    
    log_success "DMD binary verified: $DMD_BINARY"
    export DMD_BINARY
}

#################################
# STRESS TEST DEFINITIONS
#################################

# Test 1: Heavy Template Instantiation Stress
stress_test_templates() {
    local setup_cmd='cat > stress_test_templates.d << '\''EOF'\''
// Generate massive template instantiation tree
template Factorial(int n) {
    static if (n <= 1)
        enum Factorial = 1;
    else
        enum Factorial = n * Factorial!(n-1);
}

template Combinations(int n, int k) {
    static if (k == 0 || k == n)
        enum Combinations = 1;
    else
        enum Combinations = Combinations!(n-1, k-1) + Combinations!(n-1, k);
}

// Template with multiple parameters causing exponential growth
template MultiParam(int A, int B, int C, int D) {
    static if (A > 0 && B > 0)
        enum MultiParam = MultiParam!(A-1, B, C, D) + MultiParam!(A, B-1, C, D) + 
                         MultiParam!(A, B, C-1, D) + MultiParam!(A, B, C, D-1);
    else
        enum MultiParam = C * D;
}

// Recursive template generating types
template TypeGen(int depth, T) {
    static if (depth > 0) {
        struct TypeGen {
            TypeGen!(depth-1, T) left;
            TypeGen!(depth-1, T) right;
            T[depth] data;
        }
    } else {
        alias TypeGen = T;
    }
}

// Template string mixin generator
template GenerateCode(int lines) {
    static if (lines > 0)
        enum GenerateCode = "int var" ~ lines.stringof ~ " = " ~ lines.stringof ~ ";\n" ~ 
                           GenerateCode!(lines-1);
    else
        enum GenerateCode = "";
}

void main() {
    // Force instantiation of many templates
    enum f20 = Factorial!20;
    enum f25 = Factorial!25;
    
    enum c1 = Combinations!(20, 10);
    enum c2 = Combinations!(25, 12);
    enum c3 = Combinations!(30, 15);
    
    enum m1 = MultiParam!(5, 5, 5, 5);
    enum m2 = MultiParam!(6, 6, 6, 6);
    
    alias T1 = TypeGen!(10, int);
    alias T2 = TypeGen!(12, float);
    alias T3 = TypeGen!(8, string);
    
    mixin(GenerateCode!1000);
    
    // Use the values to prevent optimization
    int result = f20 + f25 + c1 + c2 + c3 + m1 + m2;
}
EOF'
    
    local test_cmd="'$DMD_BINARY' -c stress_test_templates.d -of=stress_test_templates.o"
    
    run_stress_test "template_stress" \
                   "Heavy template instantiation (exponential growth)" \
                   "$setup_cmd" \
                   "$test_cmd" \
                   300
}

# Test 2: CTFE Memory and Computation Stress
stress_test_ctfe() {
    local setup_cmd='cat > stress_test_ctfe.d << '\''EOF'\''
// Heavy CTFE computation
string generateLargeSwitch(int cases) {
    string result = "int processValue(int x) {\n  switch(x) {\n";
    foreach (i; 0 .. cases) {
        result ~= "    case " ~ i.stringof ~ ": return " ~ (i * i).stringof ~ ";\n";
    }
    result ~= "    default: return -1;\n  }\n}";
    return result;
}

int[] generatePrimes(int limit) {
    bool[] sieve = new bool[limit + 1];
    int[] primes;
    
    foreach (i; 2 .. limit + 1) {
        sieve[i] = true;
    }
    
    foreach (i; 2 .. limit + 1) {
        if (sieve[i]) {
            primes ~= i;
            for (int j = i * 2; j <= limit; j += i) {
                sieve[j] = false;
            }
        }
    }
    return primes;
}

string buildDataStructure(int size) {
    string result = "struct GeneratedStruct {\n";
    foreach (i; 0 .. size) {
        result ~= "  int field" ~ i.stringof ~ " = " ~ (i * 7).stringof ~ ";\n";
        if (i % 10 == 0) {
            result ~= "  string name" ~ i.stringof ~ " = \"field_" ~ i.stringof ~ "\";\n";
        }
    }
    result ~= "  int compute() {\n    return ";
    foreach (i; 0 .. size) {
        if (i > 0) result ~= " + ";
        result ~= "field" ~ i.stringof;
        if (i % 20 == 19) result ~= "\n      ";
    }
    result ~= ";\n  }\n}";
    return result;
}

T[n] makeArray(T, size_t n)(T value) {
    T[n] result;
    foreach (ref elem; result) {
        elem = value;
    }
    return result;
}

string recursiveStringBuild(int depth, string prefix) {
    if (depth <= 0) return prefix;
    return recursiveStringBuild(depth - 1, prefix ~ "_level" ~ depth.stringof) ~ 
           recursiveStringBuild(depth - 1, prefix ~ "_branch" ~ depth.stringof);
}

// Matrix operations at compile time
int[N][N] multiplyMatrix(int N)(int[N][N] a, int[N][N] b) {
    int[N][N] result;
    foreach (i; 0 .. N) {
        foreach (j; 0 .. N) {
            int sum = 0;
            foreach (k; 0 .. N) {
                sum += a[i][k] * b[k][j];
            }
            result[i][j] = sum;
        }
    }
    return result;
}

void main() {
    // Force heavy CTFE execution
    enum switch2000 = generateLargeSwitch(2000);
    mixin(switch2000);
    
    enum primes = generatePrimes(10000);
    enum primeCount = primes.length;
    
    enum structCode = buildDataStructure(500);
    mixin(structCode);
    
    enum arr1 = makeArray!(int, 1000)(42);
    enum arr2 = makeArray!(float, 500)(3.14);
    
    enum deepString = recursiveStringBuild(10, "root");
    
    enum int[20][20] matrix1 = 1;
    enum int[20][20] matrix2 = 2;
    enum result = multiplyMatrix!20(matrix1, matrix2);
    
    // Use values
    auto gs = GeneratedStruct();
    int value = gs.compute() + processValue(100) + primeCount + arr1[0] + cast(int)arr2[0];
}
EOF'
    
    local test_cmd="'$DMD_BINARY' -c stress_test_ctfe.d -of=stress_test_ctfe.o"
    
    run_stress_test "ctfe_stress" \
                   "Heavy CTFE computation and memory usage" \
                   "$setup_cmd" \
                   "$test_cmd" \
                   600
}

# Test 3: Symbol Resolution and Overloading Stress
stress_test_symbols() {
    local setup_cmd='cat > stress_test_symbols.d << '\''EOF'\''
// Generate massive overload sets and symbol tables
mixin template GenerateOverloads(int n) {
    static foreach (i; 0 .. n) {
        mixin("void func" ~ i.stringof ~ "(int x) { }");
        mixin("void func" ~ i.stringof ~ "(int x, int y) { }");
        mixin("void func" ~ i.stringof ~ "(string s) { }");
        mixin("void func" ~ i.stringof ~ "(float f) { }");
        mixin("void func" ~ i.stringof ~ "(int[] arr) { }");
        mixin("void func" ~ i.stringof ~ "(T)(T t) { }");
        mixin("void func" ~ i.stringof ~ "(T, U)(T t, U u) { }");
    }
}

mixin GenerateOverloads!500;

// Deep namespace nesting
mixin template GenerateNestedModules(int depth, string prefix) {
    static if (depth > 0) {
        mixin("struct " ~ prefix ~ depth.stringof ~ " {");
        mixin GenerateNestedModules!(depth - 1, prefix ~ depth.stringof);
        
        // Add members at each level
        int value;
        string name;
        
        void method1() { }
        void method2(int x) { }
        void method3(T)(T t) { }
        
        struct Inner {
            int x, y, z;
            void compute() { }
        }
        
        mixin("}");
    }
}

mixin GenerateNestedModules!(20, "Level");

// Complex inheritance hierarchies
interface I0 { void method0(); }
interface I1 : I0 { void method1(); }
interface I2 : I1 { void method2(); }
interface I3 : I2 { void method3(); }
interface I4 : I3 { void method4(); }

class Base : I4 {
    void method0() { }
    void method1() { }
    void method2() { }
    void method3() { }
    void method4() { }
}

mixin template GenerateDerivedClasses(int n) {
    static foreach (i; 0 .. n) {
        mixin("class Derived" ~ i.stringof ~ " : Base {" ~
              "  override void method0() { }" ~
              "  override void method1() { }" ~
              "  override void method2() { }" ~
              "  void specificMethod" ~ i.stringof ~ "() { }" ~
              "}");
    }
}

mixin GenerateDerivedClasses!200;

// Template constraints with complex expressions
auto complexConstraint(T, U, V)(T t, U u, V v)
if (is(T : int) && is(U : string) && is(V : float[]) &&
    is(typeof(t + 1)) && is(typeof(u.length)) && is(typeof(v[0])) &&
    __traits(compiles, t * 2) && __traits(compiles, u ~ "test"))
{
    return t;
}

// Alias chains
alias A0 = int;
mixin template GenerateAliasChain(int n) {
    static foreach (i; 1 .. n + 1) {
        mixin("alias A" ~ i.stringof ~ " = A" ~ (i-1).stringof ~ "[];");
    }
}
mixin GenerateAliasChain!50;

void main() {
    // Force symbol resolution
    func0(1);
    func100(1, 2);
    func200("test");
    func300(3.14f);
    func400([1, 2, 3]);
    
    Level20 l;
    l.Level201.Level2012.value = 42;
    
    Base b = new Derived50();
    b.method0();
    
    auto result = complexConstraint(1, "test", [1.0f, 2.0f]);
    
    A50 deepArray;
}
EOF'
    
    local test_cmd="'$DMD_BINARY' -c stress_test_symbols.d -of=stress_test_symbols.o"
    
    run_stress_test "symbol_stress" \
                   "Symbol resolution and overload set stress" \
                   "$setup_cmd" \
                   "$test_cmd" \
                   400
}

# Test 4: Code Generation Stress
stress_test_codegen() {
    local setup_cmd='cat > stress_test_codegen.d << '\''EOF'\''
// Generate massive amounts of code
mixin template GenerateFunctions(int n) {
    static foreach (i; 0 .. n) {
        mixin("int compute" ~ i.stringof ~ "(int x) {" ~
              "  int result = x;" ~
              "  for (int j = 0; j < 10; j++) {" ~
              "    result = (result * 3 + j) % 1000000;" ~
              "    if (result > 500000) result -= 250000;" ~
              "    else result += 125000;" ~
              "  }" ~
              "  return result;" ~
              "}");
    }
}

mixin GenerateFunctions!2000;

// Large switch statements
int processLargeSwitch(int x) {
    switch (x) {
        static foreach (i; 0 .. 5000) {
            case i: return i * i + i;
        }
        default: return -1;
    }
}

// Deep control flow nesting
int deeplyNested(int x) {
    int result = 0;
    for (int i1 = 0; i1 < x; i1++) {
        if (i1 % 2 == 0) {
            for (int i2 = 0; i2 < x; i2++) {
                if (i2 % 3 == 0) {
                    for (int i3 = 0; i3 < x; i3++) {
                        if (i3 % 5 == 0) {
                            for (int i4 = 0; i4 < x; i4++) {
                                if (i4 % 7 == 0) {
                                    result += i1 * i2 * i3 * i4;
                                } else {
                                    result -= i1 + i2 + i3 + i4;
                                }
                            }
                        } else {
                            result += i1 * i2 * i3;
                        }
                    }
                } else {
                    result += i1 * i2;
                }
            }
        } else {
            result += i1;
        }
    }
    return result;
}

// Large arrays and initializers
struct LargeStruct {
    int[1000] data1 = 1;
    float[500] data2 = 2.0f;
    string[100] names;
    
    this(int seed) {
        foreach (i, ref val; data1) {
            val = cast(int)(i * seed);
        }
        foreach (i, ref val; data2) {
            val = i * seed * 1.5f;
        }
        foreach (i, ref name; names) {
            name = "name_" ~ i.stringof;
        }
    }
    
    int compute() {
        int sum = 0;
        foreach (val; data1) sum += val;
        foreach (val; data2) sum += cast(int)val;
        return sum;
    }
}

// Inline assembly stress (if supported)
version(D_InlineAsm_X86_64) {
    int asmFunction(int x, int y) {
        asm {
            mov EAX, x;
            add EAX, y;
            imul EAX, EAX;
            xor EAX, 0x12345678;
            rol EAX, 3;
        }
    }
}

void main() {
    int total = 0;
    
    // Call many generated functions
    static foreach (i; 0 .. 100) {
        total += compute ~ i.stringof ~ (i);
    }
    
    total += processLargeSwitch(2500);
    total += deeplyNested(5);
    
    auto ls = LargeStruct(42);
    total += ls.compute();
    
    version(D_InlineAsm_X86_64) {
        total += asmFunction(100, 200);
    }
}
EOF'
    
    local test_cmd="'$DMD_BINARY' -c stress_test_codegen.d -of=stress_test_codegen.o"
    
    run_stress_test "codegen_stress" \
                   "Code generation stress (large output)" \
                   "$setup_cmd" \
                   "$test_cmd" \
                   600
}

# Test 5: Optimization Stress
stress_test_optimization() {
    local setup_cmd='cat > stress_test_optimization.d << '\''EOF'\''
// Code patterns that stress the optimizer
@safe pure nothrow @nogc
int pureFunction(int x) {
    return x * x + x;
}

// Constant folding opportunities
int constantFolding() {
    int result = 0;
    result += 2 * 3 * 5 * 7;
    result += 1000 / 10 / 5;
    result += (100 + 200) * (300 + 400);
    result += 1 << 10;
    result += 0xFFFF & 0x00FF;
    return result;
}

// Dead code elimination
int deadCode(int x) {
    int unused1 = x * 100;
    int unused2 = x * 200;
    int unused3 = x * 300;
    
    if (false) {
        return unused1 + unused2 + unused3;
    }
    
    int result = x;
    
    if (true) {
        result *= 2;
    } else {
        result *= 3;
        unused1 = 999;
    }
    
    return result;
}

// Loop optimization opportunities  
int loopOptimization(int[] data) {
    int sum = 0;
    
    // Loop invariant code motion
    for (int i = 0; i < data.length; i++) {
        int constant = 100 * 200;
        sum += data[i] * constant;
    }
    
    // Loop unrolling opportunity
    for (int i = 0; i < 1000; i++) {
        sum += i;
    }
    
    // Strength reduction
    for (int i = 0; i < 100; i++) {
        sum += i * 8;  // Could be replaced with shift
    }
    
    return sum;
}

// Inlining opportunities
@pragma(inline, true)
int inlineMe(int x) {
    return x + 1;
}

int callInline() {
    int result = 0;
    for (int i = 0; i < 10000; i++) {
        result += inlineMe(i);
    }
    return result;
}

// Tail recursion optimization
int factorial(int n, int acc = 1) {
    if (n <= 1) return acc;
    return factorial(n - 1, n * acc);
}

// Common subexpression elimination
int commonSubexpressions(int x, int y, int z) {
    int a = (x + y) * (z - 1);
    int b = (x + y) * (z + 1);
    int c = (x + y) * z;
    int d = (x + y) * (z * 2);
    return a + b + c + d;
}

// Escape analysis opportunities
struct Point {
    int x, y;
    
    int distanceSquared() {
        return x * x + y * y;
    }
}

int escapeAnalysis() {
    int sum = 0;
    for (int i = 0; i < 1000; i++) {
        Point p = Point(i, i * 2);  // Should not escape
        sum += p.distanceSquared();
    }
    return sum;
}

// Devirtualization opportunities
interface IOperation {
    int compute(int x);
}

final class Operation : IOperation {
    override int compute(int x) {
        return x * 2;
    }
}

int devirtualization() {
    IOperation op = new Operation();
    int sum = 0;
    for (int i = 0; i < 1000; i++) {
        sum += op.compute(i);  // Should be devirtualized
    }
    return sum;
}

void main() {
    int[1000] data;
    foreach (i, ref val; data) {
        val = cast(int)i;
    }
    
    int result = 0;
    result += constantFolding();
    result += deadCode(42);
    result += loopOptimization(data);
    result += callInline();
    result += factorial(10);
    result += commonSubexpressions(1, 2, 3);
    result += escapeAnalysis();
    result += devirtualization();
}
EOF'
    
    # Test with different optimization levels
    local test_cmd="'$DMD_BINARY' -c -O -inline -release stress_test_optimization.d -of=stress_test_optimization.o"
    
    run_stress_test "optimization_stress" \
                   "Optimizer stress test (-O -inline -release)" \
                   "$setup_cmd" \
                   "$test_cmd" \
