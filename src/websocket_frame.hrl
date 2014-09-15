-record(ws_frame, {
		fin = undefined :: undefined | boolean(),
		rsv1 = undefined :: undefined | 0..1,
		rsv2 = undefined :: undefined | 0..1,
		rsv3 = undefined :: undefined | 0..1,
		opcode = undefined :: undefined | integer(),
		mask = undefined :: undefined | 0..1,
		payload_length = undefined :: undefined | integer(),
		masking_key = <<0>> :: binary(),
		payload_data = <<>> :: binary()
	}).
