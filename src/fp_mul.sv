import fp_pkg::*;

module fp_mul
#(
    parameter fp_format_e FP_FORMAT = FP32,

    localparam int unsigned FP_WIDTH = fp_width(FP_FORMAT),
    localparam int unsigned EXP_WIDTH = exp_bits(FP_FORMAT),
    localparam int unsigned MANT_WIDTH = man_bits(FP_FORMAT),

    localparam int unsigned BIAS = (2**(EXP_WIDTH-1)-1),
    localparam INF = {{EXP_WIDTH{1'b1}}, {MANT_WIDTH{1'b0}}},
    localparam R_IND = {1'b1, {EXP_WIDTH{1'b1}}, 1'b1, {MANT_WIDTH-1{1'b0}}}
)
(
    a_i,
    b_i,
    start_i,
    done_o,
    urnd_result_o
);
`include "fp_class.sv"
input [FP_WIDTH-1:0] a_i;
input [FP_WIDTH-1:0] b_i;
input start_i;
output done_o;
output uround_res_t urnd_result_o;

fp_encoding_t result_o;
logic [1:0] rs_o;
logic round_en_o;
logic invalid_o;
logic [1:0] exp_cout_o;


logic urpr_s;
logic [2*MANT_WIDTH + 1:0] urpr_mant;
logic [EXP_WIDTH + 1:0] urpr_exp;

logic sign_o;
logic [EXP_WIDTH-1:0] exp_o;
logic [MANT_WIDTH-1:0] mant_o;

fp_encoding_t a_decoded;
fp_encoding_t b_decoded;

assign a_decoded = a_i;
assign b_decoded = b_i;

fp_info_t a_info;
fp_info_t b_info;

assign a_info = fp_info(a_i);
assign b_info = fp_info(b_i);



//precheck
always_comb
begin
    round_en_o = 1'b0;
	result_o = 0;

    if(a_info.is_nan)
    begin
        result_o.sign = a_decoded.sign;
        result_o.mant = {1'b1, a_decoded.mant[MANT_WIDTH-2:0]};
        result_o.exp = a_decoded.exp;
    end
    else if(b_info.is_nan)
    begin
        result_o.sign = b_decoded.sign;
        result_o.mant = {1'b1, b_decoded.mant[MANT_WIDTH-2:0]};
        result_o.exp = b_decoded.exp;
    end
    else if(a_info.is_inf)
        if(b_info.is_zero)
            result_o = R_IND;
        else
            result_o = {sign_o, INF};//{sign_o, 31'h7F800000};
    else if(a_info.is_normal || a_info.is_subnormal)
        if(b_info.is_inf)
            result_o = {sign_o, INF};
        else if(b_info.is_zero)
            result_o = {sign_o, {FP_WIDTH-1{1'b0}}};
        else
        begin
            round_en_o = 1'b1;
            result_o.sign = sign_o;
            result_o.mant = mant_o;
            result_o.exp = exp_o;
        end
    else if(a_info.is_zero)
        if(b_info.is_inf)
            result_o = R_IND;
        else
            result_o = {sign_o, {FP_WIDTH-1{1'b0}}};
end


assign urpr_s = a_decoded.sign ^ b_decoded.sign;
assign urpr_exp = (a_decoded.exp + b_decoded.exp) - ((a_info.is_subnormal | b_info.is_subnormal) ? BIAS-1 : BIAS );
assign urpr_mant = {a_info.is_normal, a_decoded.mant} * {b_info.is_normal, b_decoded.mant};

//normalize
logic [2*MANT_WIDTH + 1:0] shifted_mant_norm;
//calculate shift
logic [$clog2(FP_WIDTH):0] shamt;
lzc #(.WIDTH(2*MANT_WIDTH+1)) lzc_inst
(
    .a_i(urpr_mant[2*MANT_WIDTH:0]),
    .cnt_o(shamt),
    .zero_o()
);

assign shifted_mant_norm = urpr_mant << shamt; 

assign sign_o = urpr_s;
assign {exp_cout_o, exp_o} = urpr_mant[2*MANT_WIDTH + 1] ? urpr_exp + 1'b1 : urpr_exp - shamt;
assign mant_o = urpr_mant[2*MANT_WIDTH + 1] ? urpr_mant[2*MANT_WIDTH -: MANT_WIDTH] : shifted_mant_norm[2*MANT_WIDTH - 1 -: MANT_WIDTH];

//calculate RS
assign rs_o[1] = urpr_mant[2*MANT_WIDTH + 1] ? urpr_mant[MANT_WIDTH] : shifted_mant_norm[MANT_WIDTH - 1];
assign rs_o[0] = urpr_mant[2*MANT_WIDTH + 1] ? |urpr_mant[MANT_WIDTH-1:0] : |shifted_mant_norm[MANT_WIDTH - 2:0];

assign invalid_o = a_info.is_signalling | b_info.is_signalling | ((a_info.is_zero & b_info.is_inf) | (a_info.is_inf & b_info.is_zero));

assign urnd_result_o.u_result =  result_o;
assign urnd_result_o.rs =  rs_o;
assign urnd_result_o.round_en =  round_en_o;
assign urnd_result_o.invalid =  invalid_o;
assign urnd_result_o.exp_cout =  exp_cout_o;

assign done_o = start_i;

endmodule