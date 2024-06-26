import fp_pkg::*;

module fp_fma
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
    input [FP_WIDTH-1:0] a_i,
    input [FP_WIDTH-1:0] b_i,
    input [FP_WIDTH-1:0] c_i,
    input start_i,
    input sub_i,
    input roundmode_e rnd_i,
    output done_o,
    output logic round_only,
    output logic mul_ovf,
    output logic mul_uf,
    output logic mul_uround_out,
    output Structs #(.FP_FORMAT(FP_FORMAT))::uround_res_t urnd_result_o

);

Structs #(.FP_FORMAT(FP_FORMAT))::fp_encoding_t result_o;
logic [1:0] rs_o;
logic round_en_o;
logic invalid_o;
logic [1:0] exp_cout_o;

Structs #(.FP_FORMAT(FP_FORMAT))::fp_encoding_t a_decoded;
Structs #(.FP_FORMAT(FP_FORMAT))::fp_encoding_t b_decoded;
Structs #(.FP_FORMAT(FP_FORMAT))::fp_encoding_t c_decoded;

assign a_decoded = a_i;
assign b_decoded = b_i;
assign c_decoded = c_i;

fp_info_t a_info;
fp_info_t b_info;
fp_info_t c_info;

assign a_info = Functions #(.FP_FORMAT(FP_FORMAT))::fp_info(a_i);
assign b_info = Functions #(.FP_FORMAT(FP_FORMAT))::fp_info(b_i);
assign c_info = Functions #(.FP_FORMAT(FP_FORMAT))::fp_info(c_i);


////////////////////////////////////////////////////////
// Multiply 
////////////////////////////////////////////////////////
Structs #(.FP_FORMAT(FP48))::uround_res_t add_result;
localparam int unsigned FP_WIDTH_ADDER = fp_width(FP48);
localparam int unsigned EXP_WIDTH_ADDER = exp_bits(FP48);
localparam int unsigned MANT_WIDTH_ADDER = man_bits(FP48);
localparam INF_ADDER = {{EXP_WIDTH_ADDER{1'b1}}, {MANT_WIDTH_ADDER{1'b0}}};
localparam R_IND_ADDER = {1'b1, {EXP_WIDTH_ADDER{1'b1}}, 1'b1, {MANT_WIDTH_ADDER-1{1'b0}}};


Structs #(.FP_FORMAT(FP_FORMAT))::fp_encoding_t mul_result;
logic mul_round_en;
logic [1:0] mul_exp_cout;

logic mul_urpr_s;
logic [2*MANT_WIDTH + 1:0] mul_urpr_mant;
logic [EXP_WIDTH + 1:0] mul_urpr_exp;

logic mul_sign;
logic [EXP_WIDTH-1:0] mul_exp;

logic [2*MANT_WIDTH + 1:0] mul_norm_mant;
logic [FP_WIDTH_ADDER-1:0] joined_mul_result;

//precheck
always_comb
begin
    mul_round_en = 1'b0;
	mul_result = 0;

    if(a_info.is_nan)
    begin
        mul_result.sign = a_decoded.sign;
        mul_result.exp = a_decoded.exp;
    end
    else if(b_info.is_nan)
    begin
        mul_result.sign = b_decoded.sign;
        mul_result.exp = b_decoded.exp;
    end
    else if(a_info.is_inf)
        if(b_info.is_zero)
            mul_result = R_IND;
        else
            mul_result = {mul_sign, INF};
    else if(a_info.is_normal || a_info.is_subnormal)
        if(b_info.is_inf)
            mul_result = {mul_sign, INF};
        else if(b_info.is_zero)
            mul_result = {mul_sign, {FP_WIDTH-1{1'b0}}};
        else
        begin
            mul_round_en = 1'b1;
            mul_result.sign = mul_sign;
            mul_result.exp = mul_exp;
        end
    else if(a_info.is_zero)
        if(b_info.is_inf)
            mul_result = R_IND;
        else
            mul_result = {mul_sign, {FP_WIDTH-1{1'b0}}};
end

assign mul_urpr_s = a_decoded.sign ^ b_decoded.sign;
assign mul_urpr_exp = (a_decoded.exp + b_decoded.exp) - ((a_info.is_subnormal | b_info.is_subnormal) ? BIAS-1 : BIAS );
assign mul_urpr_mant = {a_info.is_normal, a_decoded.mant} * {b_info.is_normal, b_decoded.mant};

//normalize
logic [2*MANT_WIDTH + 1:0] mul_shifted_mant_norm;
//calculate shift
logic [$clog2(FP_WIDTH):0] mul_shamt;
lzc #(.WIDTH(2*MANT_WIDTH+1)) mul_lzc_inst
(
    .a_i(mul_urpr_mant[2*MANT_WIDTH:0]),
    .cnt_o(mul_shamt),
    .zero_o()
);

assign mul_shifted_mant_norm = mul_urpr_mant << mul_shamt; 

assign mul_sign = mul_urpr_s;
assign {mul_exp_cout, mul_exp} = mul_urpr_mant[2*MANT_WIDTH + 1] ? mul_urpr_exp + 1'b1 : mul_urpr_exp - mul_shamt;
assign mul_norm_mant = mul_urpr_mant[2*MANT_WIDTH + 1] ? {mul_urpr_mant[2*MANT_WIDTH : 0],1'b0} : {mul_shifted_mant_norm[2*MANT_WIDTH - 1 : 0],2'b0};

//multiply denormalize logic
logic [EXP_WIDTH-1:0] mul_uexp;
logic [2*MANT_WIDTH + 1:0] mul_umant;
logic mul_round_out;
logic [EXP_WIDTH-1:0] mul_denorm_shift;
assign mul_denorm_shift = $signed(0)-$signed({mul_exp_cout,mul_result.exp});
always_comb
begin
    mul_uexp = {EXP_WIDTH{1'b0}};
    {mul_umant, mul_round_out} = {1'b1, mul_norm_mant[2*MANT_WIDTH + 1:0]} >> mul_denorm_shift;
end

//new sticky logic
logic [EXP_WIDTH:0] stickyindex;
logic [2*MANT_WIDTH + 2:0] sigB;
logic [2*MANT_WIDTH + 2:0] compressed_mant;
logic new_stickybit;

assign sigB = {1'b1, mul_norm_mant[2*MANT_WIDTH + 1:0]};
generate
    for(genvar i = 0; i <= (2*MANT_WIDTH+2); i= i+1)
	begin : combine_sig
        assign compressed_mant[i] = |sigB[i:0];
	end
endgenerate
assign stickyindex = mul_denorm_shift - 1;

always_comb
    if($signed(stickyindex) < $signed(0))
        new_stickybit = 1'b0;
    else if($signed(stickyindex) > $signed(2*MANT_WIDTH+2))
        new_stickybit = compressed_mant[2*MANT_WIDTH+2];
    else
        new_stickybit = compressed_mant[stickyindex];

logic mult_sticky_bit;
always_comb
    if($signed({mul_exp_cout,mul_result.exp}) <= $signed(0))
        mult_sticky_bit = mul_round_out | new_stickybit;
    else
        mult_sticky_bit = 1'b0;

always_comb begin
    if ($signed({mul_exp_cout,mul_result.exp}) <= $signed(0) && !(a_info.is_zero || b_info.is_zero))
        joined_mul_result = {mul_result.sign,mul_uexp,mul_umant[2*MANT_WIDTH+1:1],mul_umant[0] | mult_sticky_bit};
    else
        joined_mul_result = {mul_result.sign,mul_result.exp,mul_norm_mant};
end
////////////////////////////////////////////////////////
// Add/Sub 
////////////////////////////////////////////////////////
logic mul_ovf_sig;
logic [FP_WIDTH_ADDER-1:0] c_int;
assign c_int = {c_i, {MANT_WIDTH+2{1'b0}}};

Structs #(.FP_FORMAT(FP48))::fp_encoding_t ab_decoded;
Structs #(.FP_FORMAT(FP48))::fp_encoding_t c_int_decoded;

assign ab_decoded       = joined_mul_result;
assign c_int_decoded    = c_int;

fp_info_t ab_info;
fp_info_t c_int_info;

assign ab_info = Functions #(.FP_FORMAT(FP48))::fp_info(joined_mul_result);
assign c_int_info = Functions #(.FP_FORMAT(FP48))::fp_info(c_int);
//////////////////////////////////////////////////////////////////////////////////////////////////////////
/*fp_add  #(.FP_FORMAT(FP48)) fp_add_inst
(
    .a_i(joined_mul_result),
    .b_i({c_i, {MANT_WIDTH+2{1'b0}}}),
    .sub_i(1'b0),
    .exp_in(mul_exp_cout),
    .round_en(mul_round_en),
    .rnd_i(rnd_i),
    .round_only(round_only),
    .mul_ovf(mul_ovf_sig),
    .mul_uf(mul_uf),
    .urnd_result_o(add_result)
);
*/
Structs #(.FP_FORMAT(FP48))::fp_encoding_t adder_result_o;
logic [1:0] adder_rs_o;
logic adder_round_en_o;
logic [1:0] adder_exp_cout_o;

logic exp_eq, exp_lt;
logic mant_eq, mant_lt;
logic lt;

logic [EXP_WIDTH_ADDER-1:0]adder_exp_diff;
logic [MANT_WIDTH_ADDER + GUARD_BITS:0]adder_shifted_mant;
logic [MANT_WIDTH_ADDER:0]adder_bigger_mant;

logic adder_urpr_s;
logic [MANT_WIDTH_ADDER + GUARD_BITS + 2:0] adder_urpr_mant;
logic [EXP_WIDTH_ADDER-1:0] adder_urpr_exp;

logic adder_sign_o;
logic [EXP_WIDTH_ADDER-1:0] adder_exp_o;
logic [MANT_WIDTH_ADDER-1:0] adder_mant_o;

logic [EXP_WIDTH_ADDER:0] adder_stickyindex;
logic [MANT_WIDTH_ADDER:0] adder_sigB;
logic [MANT_WIDTH_ADDER:0] adder_compressed_mant;
logic adder_stickybit;

logic [EXP_WIDTH_ADDER+1:0] comb_exp;
logic inf_cond;
assign comb_exp = {mul_exp_cout, ab_decoded.exp};

always_comb
begin
    adder_round_en_o = 1'b0;
	adder_result_o = 0;
    round_only = 1'b0;
    mul_ovf_sig = 1'b0;
    mul_uf = 1'b0;
    if(ab_info.is_nan)
    begin
        if(~mul_round_en)
        begin
            adder_result_o.sign = ab_decoded.sign;
            adder_result_o.mant = {1'b1, ab_decoded.mant[MANT_WIDTH_ADDER-2:0]};
            adder_result_o.exp = ab_decoded.exp;
        end
        else begin
        adder_round_en_o = 1'b1;
        adder_result_o.sign = adder_sign_o;
        adder_result_o.mant = adder_mant_o;
        adder_result_o.exp = adder_exp_o;
        end
    end
    if(c_int_info.is_nan)
    begin
        adder_result_o.sign = c_int_decoded.sign;
        adder_result_o.mant = {1'b1, c_int_decoded.mant[MANT_WIDTH_ADDER-2:0]};
        adder_result_o.exp = c_int_decoded.exp;
    end
    else if(ab_info.is_inf)
    begin
        if(~mul_round_en)
            adder_result_o = ((ab_decoded.sign ^ (sub_i ^ c_int_decoded.sign)) & ab_info.is_inf & c_int_info.is_inf)? R_IND_ADDER : ab_decoded;
        else begin
            adder_round_en_o = 1'b1;
            adder_result_o.sign = adder_sign_o;
            adder_result_o.mant = adder_mant_o;
            adder_result_o.exp = adder_exp_o;
        end
    end
    else if(inf_cond & ~c_int_info.is_inf)
    begin
        mul_ovf_sig = 1'b1;
        adder_result_o = {ab_decoded.sign, INF_ADDER};
    end
    else if(ab_info.is_normal || ab_info.is_subnormal)
        if(c_int_info.is_inf)
        begin
            adder_result_o.sign = sub_i ^ c_int_decoded.sign;
            adder_result_o.mant = c_int_decoded.mant;
            adder_result_o.exp = c_int_decoded.exp;
        end
        else if(c_int_info.is_zero)
        begin
            adder_round_en_o = 1'b1;
            round_only = 1'b1;
            mul_uf = 1'b1;
            adder_result_o = ab_decoded;
        end
        else
        begin
            if(ab_decoded.exp == c_int_decoded.exp && ab_decoded.mant == c_int_decoded.mant && (ab_decoded.sign != (sub_i ^ c_int_decoded.sign)))
            begin
                adder_result_o.sign = (rnd_i == RDN);
                adder_result_o.mant = 0;
                adder_result_o.exp = 0;
            end
            else if(ab_info.is_subnormal && c_int_info.is_subnormal)//both subnormal
            begin
                adder_round_en_o = 1'b1;
                round_only = 1'b1;
                mul_uf = 1'b1;
                adder_result_o.sign = adder_sign_o;
                adder_result_o.mant = adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS-:MANT_WIDTH_ADDER];
                adder_result_o.exp = adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 1] ? 'd1 : 'd0;
            end
            else//both normal or mixed
            begin
                adder_round_en_o = 1'b1;
                adder_result_o.sign = adder_sign_o;
                adder_result_o.mant = adder_mant_o;
                adder_result_o.exp = adder_exp_o;
            end
        end
    else if(ab_info.is_zero)
    begin
        adder_result_o.sign = sub_i ^ c_int_decoded.sign;
        adder_result_o.mant = c_int_decoded.mant;
        adder_result_o.exp = c_int_decoded.exp;
        if(c_int_info.is_zero && ((sub_i ^ c_int_info.is_minus) ^ ab_info.is_minus))
            adder_result_o.sign = (rnd_i == RDN);
    end
end

logic denormalA;
logic denormalB;

assign denormalA = (ab_info.is_subnormal ^ c_int_info.is_subnormal) & ab_info.is_subnormal;
assign denormalB = (ab_info.is_subnormal ^ c_int_info.is_subnormal) & c_int_info.is_subnormal;

assign exp_eq = (ab_decoded.exp == c_int_decoded.exp);
assign exp_lt = (ab_decoded.exp < c_int_decoded.exp);

assign mant_eq = (ab_decoded.mant == c_int_decoded.mant);
assign mant_lt = (ab_decoded.mant < c_int_decoded.mant);

assign lt = exp_lt | (exp_eq & mant_lt);

assign adder_exp_diff = lt? (c_int_decoded.exp - ab_decoded.exp) 
                    : (ab_decoded.exp - c_int_decoded.exp);

assign adder_shifted_mant = lt? ({{ab_info.is_normal | ab_info.is_nan | ab_info.is_inf, ab_decoded.mant},{GUARD_BITS{1'b0}}} >> (denormalA ? adder_exp_diff - 1 : adder_exp_diff)) 
                        : ({{c_int_info.is_normal, c_int_decoded.mant},{GUARD_BITS{1'b0}}} >> (denormalB ? adder_exp_diff - 1 : adder_exp_diff));
assign adder_bigger_mant = lt? {c_int_info.is_normal, c_int_decoded.mant} : {ab_info.is_normal | ab_info.is_nan | ab_info.is_inf, ab_decoded.mant};

assign adder_urpr_s = lt? sub_i ^ c_int_decoded.sign : ab_decoded.sign;
assign adder_urpr_mant = (ab_decoded.sign ^ (sub_i ^ c_int_decoded.sign))? ({1'b0, adder_bigger_mant,{GUARD_BITS{1'b0}},1'b0} - {1'b0,adder_shifted_mant,adder_stickybit}) 
                                                            : ({1'b0, adder_bigger_mant,{GUARD_BITS{1'b0}},1'b0} + {1'b0,adder_shifted_mant,adder_stickybit});
assign adder_urpr_exp = lt? c_int_decoded.exp : ab_decoded.exp;

//normalize
//added cout and sticky bit
logic [MANT_WIDTH_ADDER + GUARD_BITS + 1:0] adder_shifted_mant_norm;
//calculate shift

logic [$clog2(FP_WIDTH_ADDER)-1:0] adder_shamt;

lzc #(.WIDTH(MANT_WIDTH_ADDER+GUARD_BITS)) adder_lzc_inst
(
    .a_i(adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 1 : GUARD_BITS - 1]),
    .cnt_o(adder_shamt),
    .zero_o()
);

assign inf_cond  = ($signed(comb_exp) >  $signed(2**EXP_WIDTH_ADDER-1) );

logic bitout;
assign {adder_shifted_mant_norm, bitout} = adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 2]?  {adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 2:1],1'b0} >> 1'b1 
                                    : {adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 2:1],1'b0} << adder_shamt;

assign adder_sign_o = adder_urpr_s;
assign adder_mant_o = adder_shifted_mant_norm[MANT_WIDTH_ADDER + (GUARD_BITS - 1)-:MANT_WIDTH_ADDER];
assign {adder_exp_cout_o, adder_exp_o} = adder_urpr_mant[MANT_WIDTH_ADDER + GUARD_BITS + 2]? adder_urpr_exp + 1'b1 : adder_urpr_exp - adder_shamt;
//Sticky Logic
assign adder_sigB = lt? {ab_info.is_normal, ab_decoded.mant} : {c_int_info.is_normal, c_int_decoded.mant};

genvar i;
generate
    for(i = 0; i <= MANT_WIDTH_ADDER; i= i+1)
	begin : combine_sig
        assign adder_compressed_mant[i] = |adder_sigB[i:0];
	end
endgenerate
assign adder_stickyindex = adder_exp_diff - (GUARD_BITS + 1);

always_comb
    if($signed(adder_stickyindex) < $signed(0))
        adder_stickybit = 1'b0;
    else if($signed(adder_stickyindex) > $signed(MANT_WIDTH_ADDER))
        adder_stickybit = adder_compressed_mant[MANT_WIDTH_ADDER];
    else
        adder_stickybit = adder_compressed_mant[adder_stickyindex];
    

assign adder_rs_o = {adder_shifted_mant_norm[GUARD_BITS - 1], |adder_shifted_mant_norm[GUARD_BITS - 2:0] | adder_stickybit | bitout};
//////////////////////////////////////////////////////////////////////////////////////////////////////////





logic [MANT_WIDTH-1:0] mant_o;
assign mant_o = adder_result_o.mant[2*MANT_WIDTH + 1 -: MANT_WIDTH];
////////////////////////////////////////////////////////
//  Output
////////////////////////////////////////////////////////
assign rs_o[1] = adder_result_o.mant[MANT_WIDTH + 1];
assign rs_o[0] = (|adder_result_o.mant[MANT_WIDTH:0]) | (|adder_rs_o) | mult_sticky_bit;
assign invalid_o = a_info.is_signalling | b_info.is_signalling | c_info.is_signalling | 
                    ((a_info.is_inf & b_info.is_zero) | (a_info.is_zero & b_info.is_inf)) |
                    (!a_info.is_nan && !b_info.is_nan && c_info.is_inf & ((mul_result.sign ^ (sub_i ^ c_decoded.sign)) & (a_info.is_inf | b_info.is_inf)));

always_comb
    case (rnd_i)
        RNE, RMM :  mul_uround_out = ~adder_result_o.mant[MANT_WIDTH];
        default:    mul_uround_out = ~(|adder_rs_o) & (rs_o == 2'b01 | rs_o == 2'b10);
    endcase


////////////////////////////////////////////////////////
// Pre-check 
////////////////////////////////////////////////////////
always_comb
begin
    round_en_o = 1'b0;
	result_o = 0;
    mul_ovf = 1'b0;

    if((a_info.is_inf & b_info.is_zero) | (a_info.is_zero & b_info.is_inf))
        result_o = R_IND;
    else if(a_info.is_nan)
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
    else if(c_info.is_nan)
    begin
        result_o.sign = c_decoded.sign;
        result_o.mant = {1'b1, c_decoded.mant[MANT_WIDTH-2:0]};
        result_o.exp = c_decoded.exp;
    end
    else if(c_info.is_inf)
        // This should be calculated as finite inputs can result in infinite output due to ovf
        // Maybe you already checked that in adder
        result_o = ((mul_result.sign ^ (sub_i ^ c_decoded.sign)) & (a_info.is_inf | b_info.is_inf))? R_IND : c_decoded;
    else
    begin
        round_en_o       = adder_round_en_o;
        result_o.sign    = adder_result_o.sign;
        result_o.mant    = mant_o;
        result_o.exp     = adder_result_o.exp;
        mul_ovf          = mul_ovf_sig & ~invalid_o;
    end
end

assign urnd_result_o.u_result   =  result_o;
assign urnd_result_o.rs         =  rs_o;
assign urnd_result_o.round_en   =  round_en_o;
assign urnd_result_o.invalid    =  invalid_o;
assign urnd_result_o.exp_cout   =  adder_exp_cout_o;

assign done_o = start_i;
endmodule