// 
// Copyright (C) 2011-2014 Jeff Bush
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

module fpga_top(
	input						clk50,

	// Der blinkenlights
	output logic[17:0]			red_led,
	output logic[8:0]			green_led,
	output logic[6:0]			hex0,
	output logic[6:0]			hex1,
	output logic[6:0]			hex2,
	output logic[6:0]			hex3,
	
	// UART
	output						uart_tx,
	input						uart_rx,

	// SDRAM	
	output						dram_clk,
	output 						dram_cke, 
	output 						dram_cs_n, 
	output 						dram_ras_n, 
	output 						dram_cas_n, 
	output 						dram_we_n,
	output [1:0]				dram_ba,	
	output [12:0] 				dram_addr,
	output [3:0]				dram_dqm,
	inout [31:0]				dram_dq,
	
	// VGA
	output [7:0]				vga_r,
	output [7:0]				vga_g,
	output [7:0]				vga_b,
	output 						vga_clk,
	output 						vga_blank_n,
	output 						vga_hs,
	output 						vga_vs,
	output 						vga_sync_n);

	// We always access the full word width, so hard code these to active (low)
	assign dram_dqm = 4'b0000;

	/*AUTOWIRE*/
	// Beginning of automatic wires (for undeclared instantiated-module outputs)
	logic		DEBUG_retire_sync_store;// From gpgpu of gpgpu.v
	l1_miss_entry_idx_t DEBUG_storebuf_l2_response_idx;// From gpgpu of gpgpu.v
	wire		DEBUG_storebuf_l2_response_valid;// From gpgpu of gpgpu.v
	wire		DEBUG_storebuf_l2_sync_success;// From gpgpu of gpgpu.v
	scalar_t	DEBUG_sync_address;	// From gpgpu of gpgpu.v
	thread_idx_t	DEBUG_sync_id;		// From gpgpu of gpgpu.v
	wire [31:0]	io_address;		// From gpgpu of gpgpu.v
	wire		io_read_en;		// From gpgpu of gpgpu.v
	wire [31:0]	io_write_data;		// From gpgpu of gpgpu.v
	wire		io_write_en;		// From gpgpu of gpgpu.v
	logic		pc_event_dram_page_hit;	// From sdram_controller of sdram_controller.v
	logic		pc_event_dram_page_miss;// From sdram_controller of sdram_controller.v
	wire		processor_halt;		// From gpgpu of gpgpu.v
	// End of automatics

	axi_interface axi_bus_m0();
	axi_interface axi_bus_m1();
	axi_interface axi_bus_s0();
	axi_interface axi_bus_s1();
	logic reset;
	wire[31:0] loader_addr;
	wire[31:0] loader_data;
	wire loader_we;
	logic clk;
	scalar_t io_read_data;
	
	assign clk = clk50;

	/* gpgpu AUTO_TEMPLATE(
		.axi_bus(axi_bus_s0[]),
		);
	*/
	gpgpu gpgpu(
		/*AUTOINST*/
		    // Interfaces
		    .axi_bus		(axi_bus_s0),		 // Templated
		    // Outputs
		    .processor_halt	(processor_halt),
		    .io_write_en	(io_write_en),
		    .io_read_en		(io_read_en),
		    .io_address		(io_address[31:0]),
		    .io_write_data	(io_write_data[31:0]),
		    .DEBUG_is_sync_store(DEBUG_is_sync_store),
		    .DEBUG_is_sync_load	(DEBUG_is_sync_load),
		    .DEBUG_sync_id	(DEBUG_sync_id),
		    .DEBUG_sync_store_success(DEBUG_sync_store_success),
		    .DEBUG_sync_address	(DEBUG_sync_address),
		    .DEBUG_retire_sync_store(DEBUG_retire_sync_store),
		    .DEBUG_retire_sync_success(DEBUG_retire_sync_success),
		    .DEBUG_retire_thread(DEBUG_retire_thread),
		    .DEBUG_storebuf_l2_response_valid(DEBUG_storebuf_l2_response_valid),
		    .DEBUG_storebuf_l2_response_idx(DEBUG_storebuf_l2_response_idx),
		    .DEBUG_storebuf_l2_sync_success(DEBUG_storebuf_l2_sync_success),
		    // Inputs
		    .clk		(clk),
		    .reset		(reset),
		    .io_read_data	(io_read_data[31:0]));
	
	axi_interconnect axi_interconnect(
		/*AUTOINST*/
					  // Interfaces
					  .axi_bus_m0		(axi_bus_m0),
					  .axi_bus_m1		(axi_bus_m1),
					  .axi_bus_s0		(axi_bus_s0),
					  .axi_bus_s1		(axi_bus_s1),
					  // Inputs
					  .clk			(clk),
					  .reset		(reset));
			  
	// Internal SRAM.  The system boots out of this.
	/* axi_internal_ram AUTO_TEMPLATE(
		.axi_bus(axi_bus_m0),);
	*/
	axi_internal_ram #(.MEM_SIZE('h800)) axi_internal_ram(
		/*AUTOINST*/
							      // Interfaces
							      .axi_bus		(axi_bus_m0),	 // Templated
							      // Inputs
							      .clk		(clk),
							      .reset		(reset),
							      .loader_we	(loader_we),
							      .loader_addr	(loader_addr[31:0]),
							      .loader_data	(loader_data[31:0]));

	// This module loads data over JTAG into axi_internal_ram and resets
	// the core.
	jtagloader jtagloader(
		.we(loader_we),
		.addr(loader_addr),
		.data(loader_data),
		.reset(reset),
		.clk(clk));
		
	/* sdram_controller AUTO_TEMPLATE(
		.clk(clk),
		.axi_bus(axi_bus_m1),);
	*/
	sdram_controller #(
			.DATA_WIDTH(32), 
			.ROW_ADDR_WIDTH(13), 
			.COL_ADDR_WIDTH(10),

			// 50 Mhz = 20ns clock.  Each value is clocks of delay minus one.
			// Timing values based on datasheet for A3V64S40ETP SDRAM parts
			// on the DE2-115 board.
			.T_REFRESH(390),          // 64 ms / 8192 rows = 7.8125 uS  
			.T_POWERUP(10000),        // 200 us		
			.T_ROW_PRECHARGE(1),      // 21 ns	
			.T_AUTO_REFRESH_CYCLE(3), // 75 ns
			.T_RAS_CAS_DELAY(1),      // 21 ns	
			.T_CAS_LATENCY(1)		  // 21 ns (2 cycles)
		) sdram_controller(
			/*AUTOINST*/
				   // Interfaces
				   .axi_bus		(axi_bus_m1),	 // Templated
				   // Outputs
				   .dram_clk		(dram_clk),
				   .dram_cke		(dram_cke),
				   .dram_cs_n		(dram_cs_n),
				   .dram_ras_n		(dram_ras_n),
				   .dram_cas_n		(dram_cas_n),
				   .dram_we_n		(dram_we_n),
				   .dram_ba		(dram_ba[1:0]),
				   .dram_addr		(dram_addr[12:0]),
				   .pc_event_dram_page_miss(pc_event_dram_page_miss),
				   .pc_event_dram_page_hit(pc_event_dram_page_hit),
				   // Inouts
				   .dram_dq		(dram_dq[31:0]),
				   // Inputs
				   .clk			(clk),		 // Templated
				   .reset		(reset));

	/* vga_controller AUTO_TEMPLATE(
		.axi_bus(axi_bus_s1));
	*/
	vga_controller vga_controller(
		/*AUTOINST*/
				      // Interfaces
				      .axi_bus		(axi_bus_s1),	 // Templated
				      // Outputs
				      .vga_r		(vga_r[7:0]),
				      .vga_g		(vga_g[7:0]),
				      .vga_b		(vga_b[7:0]),
				      .vga_clk		(vga_clk),
				      .vga_blank_n	(vga_blank_n),
				      .vga_hs		(vga_hs),
				      .vga_vs		(vga_vs),
				      .vga_sync_n	(vga_sync_n),
				      // Inputs
				      .clk		(clk),
				      .reset		(reset));

	logic[31:0] capture_data;
	logic capture_enable;
	logic trigger;
	logic[31:0] clock_count;
	
	assign capture_data = { 
		8'b10101010,
		4'b0000, DEBUG_retire_sync_store, DEBUG_retire_sync_success, DEBUG_retire_thread,
		3'b000, DEBUG_is_sync_store, DEBUG_is_sync_load, DEBUG_sync_store_success, DEBUG_sync_id,
		4'b0000, DEBUG_storebuf_l2_response_valid, DEBUG_storebuf_l2_sync_success, DEBUG_storebuf_l2_response_idx,
	 };

	assign capture_enable = DEBUG_is_sync_store || DEBUG_is_sync_load;
	assign trigger = clock_count == 100000;

	debug_trace #(.CAPTURE_WIDTH_BITS($bits(capture_data)), .CAPTURE_SIZE(128),
		.BAUD_DIVIDE(50000000 / 115200)) debug_trace(.*);

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
			clock_count <= 0;
		else
			clock_count <= clock_count + 1;
	end

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			red_led <= 0;
			green_led <= 0;
			hex0 <= 7'b1111111;
			hex1 <= 7'b1111111;
			hex2 <= 7'b1111111;
			hex3 <= 7'b1111111;
		end
		else
		begin
			if (io_write_en)
			begin
				case (io_address)
					0: red_led <= io_write_data[17:0];
					4: green_led <= io_write_data[8:0];
					8: hex0 <= io_write_data[6:0];
					12: hex1 <= io_write_data[6:0];
					16: hex2 <= io_write_data[6:0];
					20: hex3 <= io_write_data[6:0];
				endcase
			end
		end
	end
endmodule

// Local Variables:
// verilog-library-flags:("-y ../core" "-y ../testbench" "-y ../../fpga_common")
// verilog-auto-inst-param-value: t
// End:
