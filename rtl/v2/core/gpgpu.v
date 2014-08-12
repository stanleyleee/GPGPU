//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// Top level block for GPGPU.  Contains all cores and L2 cache, connects
// to AXI system bus.
//

module gpgpu(
	input                 clk,
	input                 reset,
	axi_interface.master  axi_bus,
	output                processor_halt,

	// Non-cacheable memory signals
	output            io_write_en,
	output            io_read_en,
	output[31:0]      io_address,
	output[31:0]      io_write_data,
	input [31:0]      io_read_data,
	
	// DEBUG
	output logic                 DEBUG_is_sync_store,
	output logic                 DEBUG_is_sync_load,
	output thread_idx_t          DEBUG_sync_id,
	output logic                 DEBUG_sync_store_success,
	output scalar_t              DEBUG_sync_address,
	output logic                 DEBUG_retire_sync_store,
	output logic                 DEBUG_retire_sync_success,
	output thread_idx_t          DEBUG_retire_thread,
	output                       DEBUG_storebuf_l2_response_valid,
	output l1_miss_entry_idx_t   DEBUG_storebuf_l2_response_idx,
	output                       DEBUG_storebuf_l2_sync_success,
	output logic      DEBUG_sq_sync_response,
	output logic      DEBUG_sq_sync_result,
	output thread_idx_t DEBUG_sq_sync_thread);
	
	l2req_packet_t l2i_request[`NUM_CORES];
	l2rsp_packet_t l2_response;
	logic l2_ready[`NUM_CORES];
	logic[`NUM_CORES - 1:0] core_halt;
	ioreq_packet_t io_request[`NUM_CORES];
	logic ia_ready[`NUM_CORES];
	iorsp_packet_t ia_response;

	assign processor_halt = |core_halt;

	genvar core_idx;
	generate
		for (core_idx = 0; core_idx < `NUM_CORES; core_idx++)
		begin : core_gen
			core #(.CORE_ID(core_idx)) core(
				.l2i_request(l2i_request[core_idx]),
				.l2_ready(l2_ready[core_idx]),
				.processor_halt(core_halt[core_idx]),
				.ior_request(io_request[core_idx]),
				.ia_ready(ia_ready[core_idx]),
				.ia_response(ia_response),
				.*);
		end
	endgenerate
	
	l2_cache l2_cache(.*);
	io_arbiter io_arbiter(.*);
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:
