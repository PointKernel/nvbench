/*
 *  Copyright 2020 NVIDIA Corporation
 *
 *  Licensed under the Apache License, Version 2.0 with the LLVM exception
 *  (the "License"); you may not use this file except in compliance with
 *  the License.
 *
 *  You may obtain a copy of the License at
 *
 *      http://llvm.org/foundation/relicensing/LICENSE.txt
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include <nvbench/detail/measure_cold.cuh>

#include <nvbench/benchmark_base.cuh>
#include <nvbench/device_info.cuh>
#include <nvbench/printer_base.cuh>
#include <nvbench/state.cuh>
#include <nvbench/summary.cuh>

#include <nvbench/detail/statistics.cuh>

#include <fmt/format.h>

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <variant>

namespace nvbench::detail
{

measure_cold_base::measure_cold_base(state &exec_state)
    : m_state{exec_state}
    , m_min_samples{exec_state.get_min_samples()}
    , m_max_noise{exec_state.get_max_noise()}
    , m_min_time{exec_state.get_min_time()}
    , m_skip_time{exec_state.get_skip_time()}
    , m_timeout{exec_state.get_timeout()}
{}

void measure_cold_base::check()
{
  const auto device = m_state.get_device();
  if (!device)
  {
    throw std::runtime_error(fmt::format("{}:{}: Device required for `cold` "
                                         "measurement.",
                                         __FILE__,
                                         __LINE__));
  }
  if (!device->is_active())
  { // This means something went wrong higher up. Throw an error.
    throw std::runtime_error(fmt::format("{}:{}: Internal error: Current "
                                         "device is not active.",
                                         __FILE__,
                                         __LINE__));
  }
}

void measure_cold_base::generate_summaries()
{
  const auto d_samples = static_cast<double>(m_total_samples);
  {
    auto &summ = m_state.add_summary("Number of Samples (Cold)");
    summ.set_string("hint", "sample_size");
    summ.set_string("short_name", "Samples");
    summ.set_string("description",
                    "Number of kernel executions in cold time measurements.");
    summ.set_int64("value", m_total_samples);
  }

  const auto avg_cpu_time = m_total_cpu_time / d_samples;
  {
    auto &summ = m_state.add_summary("Average CPU Time (Cold)");
    summ.set_string("hint", "duration");
    summ.set_string("short_name", "CPU Time");
    summ.set_string("description",
                    "Average isolated kernel execution time observed "
                    "from host.");
    summ.set_float64("value", avg_cpu_time);
  }

  {
    auto &summ = m_state.add_summary("CPU Relative Standard Deviation (Cold)");
    summ.set_string("hint", "percentage");
    summ.set_string("short_name", "Noise");
    summ.set_string("description",
                    "Relative standard deviation of the cold CPU execution "
                    "time measurements.");
    summ.set_float64("value", m_cpu_noise);
  }

  const auto avg_cuda_time = m_total_cuda_time / d_samples;
  {
    auto &summ = m_state.add_summary("Average GPU Time (Cold)");
    summ.set_string("hint", "duration");
    summ.set_string("short_name", "GPU Time");
    summ.set_string("description",
                    "Average isolated kernel execution time as measured "
                    "by CUDA events.");
    summ.set_float64("value", avg_cuda_time);
  }

  {
    auto &summ = m_state.add_summary("GPU Relative Standard Deviation (Cold)");
    summ.set_string("hint", "percentage");
    summ.set_string("short_name", "Noise");
    summ.set_string("description",
                    "Relative standard deviation of the cold GPU execution "
                    "time measurements.");
    summ.set_float64("value", m_cuda_noise);
  }

  if (!m_cuda_times.empty())
  { // Percentiles and histogram:
    const auto percentiles = std::vector<int>{0, 1, 25, 50, 75, 99, 100};
    std::sort(m_cuda_times.begin(), m_cuda_times.end());
    const auto results = nvbench::detail::compute_percentiles(m_cuda_times,
                                                              percentiles);

    const auto histo_min    = results[1]; // 1st percentile
    const auto histo_max    = results[5]; // 99th percentile
    const auto histo_bins   = std::size_t{50};
    const auto histo_stride = (histo_max - histo_min) /
                              static_cast<double>(histo_bins);

    const auto histo = nvbench::detail::compute_histogram(m_cuda_times,
                                                          histo_min,
                                                          histo_stride,
                                                          histo_bins);
    {
      auto &summ = m_state.add_summary("GPU Time Percentiles (Cold)");
      summ.set_string("hide", "Non-standard format.");
      summ.set_string("hint", "percentiles");
      assert(percentiles.size() == results.size());
      for (std::size_t i = 0; i < results.size(); ++i)
      {
        fmt::print("Percentile {:<3}: {}\n", percentiles[i], results[i]);
        summ.set_float64(fmt::format("{}", percentiles[i]), results[i]);
      }
    }

    {
      auto &summ = m_state.add_summary("GPU Time Histogram (Cold)");
      summ.set_string("hide", "Non-standard format.");
      summ.set_string("hint", "histogram");
      summ.set_float64("min", histo_min);
      summ.set_float64("stride", histo_stride);
      summ.set_int64("bins", static_cast<nvbench::int64_t>(histo_bins));
      assert(histo.size() == histo_bins + 2);
      const auto scale =
        std::reduce(histo.cbegin(), histo.cend(), 0, [](auto a, auto b) {
          return a > b ? a : b;
        });
      for (std::size_t i = 0; i < histo_bins + 2; ++i)
      {
        fmt::print("Bin {:<2}: {:5} |{:0>{}}\n",
                   i,
                   histo[i],
                   "|",
                   (histo[i] * 50) / scale);
        summ.set_int64(fmt::format("bin {}", i), histo[i]);
      }
    }
  }

  if (const auto items = m_state.get_element_count(); items != 0)
  {
    auto &summ = m_state.add_summary("Element Throughput");
    summ.set_string("hint", "item_rate");
    summ.set_string("short_name", "Elem/s");
    summ.set_string("description",
                    "Number of input elements handled per second.");
    summ.set_float64("value", static_cast<double>(items) / avg_cuda_time);
  }

  if (const auto bytes = m_state.get_global_memory_rw_bytes(); bytes != 0)
  {
    const auto avg_used_gmem_bw = static_cast<double>(bytes) / avg_cuda_time;
    {
      auto &summ = m_state.add_summary("Average Global Memory Throughput");
      summ.set_string("hint", "byte_rate");
      summ.set_string("short_name", "GlobalMem BW");
      summ.set_string("description",
                      "Number of bytes read/written per second to the CUDA "
                      "device's global memory.");
      summ.set_float64("value", avg_used_gmem_bw);
    }

    {
      const auto peak_gmem_bw = static_cast<double>(
        m_state.get_device()->get_global_memory_bus_bandwidth());

      auto &summ = m_state.add_summary("Percent Peak Global Memory Throughput");
      summ.set_string("hint", "percentage");
      summ.set_string("short_name", "BWPeak");
      summ.set_string("description",
                      "Global device memory throughput as a percentage of the "
                      "device's peak bandwidth.");
      summ.set_float64("value", avg_used_gmem_bw / peak_gmem_bw * 100.);
    }
  }

  // Log if a printer exists:
  if (auto printer_opt_ref = m_state.get_benchmark().get_printer();
      printer_opt_ref.has_value())
  {
    auto &printer = printer_opt_ref.value().get();

    if (m_max_time_exceeded)
    {
      const auto timeout = m_timeout_timer.get_duration();

      if (m_cuda_noise > m_max_noise)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "while over noise threshold ({:0.2f}% > "
                                "{:0.2f}%)",
                                timeout,
                                m_cuda_noise,
                                m_max_noise));
      }
      if (m_total_samples < m_min_samples)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "before accumulating min_samples ({} < {})",
                                timeout,
                                m_total_samples,
                                m_min_samples));
      }
      if (m_total_cuda_time < m_min_time)
      {
        printer.log(nvbench::log_level::warn,
                    fmt::format("Current measurement timed out ({:0.2f}s) "
                                "before accumulating min_time ({:0.2f}s < "
                                "{:0.2f}s)",
                                timeout,
                                m_total_cuda_time,
                                m_min_time));
      }
    }

    // Log to stdout:
    printer.log(nvbench::log_level::pass,
                fmt::format("Cold: {:0.6f}ms GPU, {:0.6f}ms CPU, {:0.2f}s "
                            "total GPU, {}x",
                            avg_cuda_time * 1e3,
                            avg_cpu_time * 1e3,
                            m_total_cuda_time,
                            m_total_samples));
  }
}

void measure_cold_base::check_skip_time(nvbench::float64_t warmup_time)
{
  if (m_skip_time > 0. && warmup_time < m_skip_time)
  {
    auto reason = fmt::format("Warmup time did not meet skip_time limit: "
                              "{:0.3f}us < {:0.3f}us.",
                              warmup_time * 1e6,
                              m_skip_time * 1e6);

    m_state.skip(reason);
    throw std::runtime_error{std::move(reason)};
  }
}

} // namespace nvbench::detail
