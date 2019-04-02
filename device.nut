// Which UART we're using
uart <- hardware.uart1;

// Callback that's fired when new data has been received
// Here, we just pull all we can from the UART FIFO and send it immediately
// to the agent
function rx() {
    local data = uart.readblob();
    agent.send("rxdata", data);
}

// Handler for transmit data from the agent; we just put it in the TX FIFO.
// Note that transmits will block until they're complete, so sending blocks
// bigger than the space available in the TX FIFO isn't optimal
agent.on("txdata", function(v) {
    uart.write(v);
});

// Configure the UART's FIFO sizes and baudrate
uart.setrxfifosize(8*1024);
uart.settxfifosize(8*1024);
uart.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS, rx);
