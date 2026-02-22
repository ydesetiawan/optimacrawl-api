# zjit_bench.rb
require 'benchmark'

puts "Is ZJIT enabled? #{defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?}"

# A method that does a lot of repetitive math to give the JIT compiler something to optimize
def compute_heavy_workload
  sum = 0
  10_000.times do
    1000.times do |i|
      sum += (i * 2) - 1
    end
  end
  sum
end

# Warmup the JIT compiler (JIT compilers need to see the code run a few times before they optimize it)
compute_heavy_workload

Benchmark.bm do |x|
  x.report("workload:") do
    compute_heavy_workload
  end
end
