module l2_arbiter_mux(
	input				clk,
	output 				pci_valid_o,
	input				pci_ack_i,
	output reg[3:0]		pci_id_o,
	output reg[1:0]		pci_op_o,
	output reg[1:0]		pci_way_o,
	output reg[25:0]	pci_address_o,
	output reg[511:0]	pci_data_o,
	output reg[63:0]	pci_mask_o,
	output				unit0_selected,
	output				unit1_selected,
	output				unit2_selected,
	input				unit0_valid,
	input [3:0]			unit0_id,
	input [1:0]			unit0_op,
	input [1:0]			unit0_way,
	input [25:0]		unit0_address,
	input [511:0]		unit0_data,
	input [63:0]		unit0_mask,
	input 				unit1_valid,
	input [3:0]			unit1_id,
	input [1:0]			unit1_op,
	input [1:0]			unit1_way,
	input [25:0]		unit1_address,
	input [511:0]		unit1_data,
	input [63:0]		unit1_mask,
	input 				unit2_valid,
	input [3:0]			unit2_id,
	input [1:0]			unit2_op,
	input [1:0]			unit2_way,
	input [25:0]		unit2_address,
	input [511:0]		unit2_data,
	input [63:0]		unit2_mask);

	reg[1:0]			selected_unit = 0;
	reg 				unit_selected = 0;

	assign unit0_selected = selected_unit == 0 && unit_selected;
	assign unit1_selected = selected_unit == 1 && unit_selected;
	assign unit2_selected = selected_unit == 2 && unit_selected;

	// L2 arbiter
	always @*
	begin
		case (selected_unit)
			2'd0:
			begin
				pci_id_o = unit0_id;
				pci_op_o = unit0_op;
				pci_way_o = unit0_way;
				pci_address_o = unit0_address;
				pci_data_o = unit0_data;
				pci_mask_o = unit0_mask;
			end

			2'd1:
			begin
				pci_id_o = unit1_id;
				pci_op_o = unit1_op;
				pci_way_o = unit1_way;
				pci_address_o = unit1_address;
				pci_data_o = unit1_data;
				pci_mask_o = unit1_mask;
			end

			2'd2:
			begin
				pci_id_o = unit2_id;
				pci_op_o = unit2_op;
				pci_way_o = unit2_way;
				pci_address_o = unit2_address;
				pci_data_o = unit2_data;
				pci_mask_o = unit2_mask;
			end
			
			default:
			begin
				pci_id_o = 0;
				pci_op_o = 0;
				pci_way_o = 0;
				pci_address_o = 0;
				pci_data_o = 0;
				pci_mask_o = 0;
			end
		endcase
	end
	
	assign pci_valid_o = unit_selected && !pci_ack_i;
	
	always @(posedge clk)
	begin
		if (unit_selected)
		begin
			// Check for end of send
			if (pci_ack_i)
				unit_selected <= #1 0;
		end
		else
		begin
			// Chose a new unit		
			unit_selected <= #1 (unit0_valid || unit1_valid || unit2_valid);
			if (unit0_valid)
				selected_unit <= #1 0;
			else if (unit1_valid)
				selected_unit <= #1 1;
			else if (unit2_valid)
				selected_unit <= #1 2;
		end
	end
endmodule