{ pkgs ? import <nixpkgs> {},
  raptorjitAname ? "A",
  raptorjitBname ? "B",
  raptorjitCname ? "C",
  raptorjitDname ? "D",
  raptorjitEname ? "E",
  raptorjitAsrc,
  raptorjitBsrc ? null,
  raptorjitCsrc ? null,
  raptorjitDsrc ? null,
  raptorjitEsrc ? null,
  raptorjitAargs ? "",
  raptorjitBargs ? "",
  raptorjitCargs ? "",
  raptorjitDargs ? "",
  raptorjitEargs ? "",
  testsuiteSrc,
  hardware ? null,
  benchmarkRuns ? 1 }:

with pkgs;
with stdenv;

# RaptorJIT build derivation
let buildRaptorJIT = raptorjitName: raptorjitSrc: clangStdenv.mkDerivation {
    name = "raptorjit-${raptorjitName}";
    version = raptorjitName;
    src = raptorjitSrc;
    buildInputs = [ luajit ];
    enableParallelBuilding = true;
    installPhase = ''
      mkdir -p $out/bin
      cp src/luajit $out/bin/raptorjit
    '';
  }; in

# RaptorJIT benchmark run derivatin
# Run the standard RaptorJIT benchmarks many times and produce a CSV file.
let benchmarkRaptorJIT = raptorjitName: raptorjitSrc: raptorjitArgs:
  let raptorjit = (buildRaptorJIT raptorjitName raptorjitSrc); in
  mkDerivation {
    name = "raptorjit-${raptorjitName}-benchmarks";
    src = testsuiteSrc;
    # Force consistent hardware
    requiredSystemFeatures = if hardware != null then [hardware] else [];
    buildInputs = [ raptorjit linuxPackages.perf ];
    buildPhase = ''
      PATH=raptorjit/bin:$perf/bin:$PATH
      # Run multiple iterations of the benchmarks
      for run in $(seq 1 ${toString benchmarkRuns}); do
        echo "Run $run"
        mkdir -p result/$run
        # Run each individual benchmark
        cat bench/PARAM_x86_CI.txt |
          (cd bench
           while read benchmark params; do
             echo "running $benchmark"
             # Execute with performance monitoring & time supervision
             # Note: discard stdout due to overwhelming output
             timeout -sKILL 60 \
               perf stat -x, -o ../result/$run/$benchmark.perf \
               raptorjit ${raptorjitArgs} -e "math.randomseed($run)" $benchmark.lua $params \
                  > /dev/null || \
                  rm result/$run/$benchmark.perf
          done)
      done
    '';
    installPhase = ''
      # Copy the raw perf output for reference
      cp -r result $out
      # Create a CSV file
      for resultdir in result/*; do
        run=$(basename $resultdir)
        # Create the rows based on the perf logs
        for result in $resultdir/*.perf; do
          raptorjit=${raptorjit.version}
          benchmark=$(basename -s.perf -a $result)
          instructions=$(awk -F, -e '$3 == "instructions" { print $1; }' $result)
          cycles=$(      awk -F, -e '$3 == "cycles"       { print $1; }' $result)
          echo $raptorjit,$benchmark,$run,$instructions,$cycles >> $out/bench.csv
        done
      done
    '';
  }; in

rec {
  benchmarksA = (benchmarkRaptorJIT raptorjitAname raptorjitAsrc raptorjitAargs);
  benchmarksB = if raptorjitBsrc != null then (benchmarkRaptorJIT raptorjitBname raptorjitBsrc raptorjitBargs) else "";
  benchmarksC = if raptorjitCsrc != null then (benchmarkRaptorJIT raptorjitCname raptorjitCsrc raptorjitCargs) else "";
  benchmarksD = if raptorjitDsrc != null then (benchmarkRaptorJIT raptorjitDname raptorjitDsrc raptorjitDargs) else "";
  benchmarksE = if raptorjitEsrc != null then (benchmarkRaptorJIT raptorjitEname raptorjitEsrc raptorjitEargs) else "";

  benchmarkResults = mkDerivation {
    name = "benchmark-results";
    buildInputs = with pkgs.rPackages; [ rmarkdown ggplot2 dplyr pkgs.R pkgs.pandoc pkgs.which ];
    builder = pkgs.writeText "builder.csv" ''
      source $stdenv/setup
      # Get the CSV file
      mkdir -p $out/nix-support
      echo "raptorjit,benchmark,run,instructions,cycles" > bench.csv
      cat ${benchmarksA}/bench.csv >> bench.csv
      cat ${benchmarksB}/bench.csv >> bench.csv || true # may not exist
      cat ${benchmarksC}/bench.csv >> bench.csv || true
      cat ${benchmarksD}/bench.csv >> bench.csv || true
      cat ${benchmarksE}/bench.csv >> bench.csv || true
      cp bench.csv $out
      echo "file CSV $out/bench.csv" >> $out/nix-support/hydra-build-products
      # Generate the report
      cp ${./benchmark-results.Rmd} benchmark-results.Rmd
      cat benchmark-results.Rmd
      echo "library(rmarkdown); render('benchmark-results.Rmd')"| R --no-save
      cp benchmark-results.html $out
      echo "file HTML $out/benchmark-results.html"  >> $out/nix-support/hydra-build-products
    '';
  };
}

