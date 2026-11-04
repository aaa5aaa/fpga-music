set_device -device_version B GW5AT-LV60PG484AC1/I0
add_file src/acg720_instrument.v
add_file src/lcd_dashboard.v
add_file src/adc128s102.v
add_file src/seg7_595.v
add_file src/ES8388_Init.v
add_file src/ES8388_int_table.v
add_file src/I2C_Init_Dev.v
add_file src/audio_effects.v
add_file src/btn_debounce.v
add_file src/bt_cmd.v
add_file src/bt_rx_frame.v
add_file src/control_keys.v
add_file src/i2c_bit_shift.v
add_file src/i2c_control.v
add_file src/i2s_master.v
add_file src/key_scan_8x4.v
add_file src/note_turning.v
add_file src/poly_test.v
add_file src/rotary_vol.v
add_file src/spi_byte.v
add_file src/flash_xact.v
add_file src/flash_song.v
add_file src/ws2812_piano.v
add_file src/recorder.v
add_file src/sine_lut.v
add_file src/song_engine.v
add_file src/synth_voice.v
add_file src/uart_rx.v
add_file src/uart_tx.v
add_file src/fpga_project.sdc
add_file src/fpga_project.cst
set_option -top_module acg720_instrument
set_option -use_sspi_as_gpio 1
set_option -opt_goal timing
run all

