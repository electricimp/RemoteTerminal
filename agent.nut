// hugo@electricimp.com 20190317
//
// Simple serial terminal using xtermjs
// See https://connect.electricimp.com/blog/secure-web-based-serial-terminal for more detail
#require "rocky.class.nut:2.0.2"

AUTH <- "username:password";
debug <- false;

// The webpage we serve when visiting the agent URL. Note the single "%s" used
// to inject the agent URL 
const HTML_STRING = @"<!doctype html>
 <html>
   <head>
     <link rel=""stylesheet"" href=""https://unpkg.com/xterm/dist/xterm.css"" />
     <script src=""https://unpkg.com/xterm/dist/xterm.js""></script>
   </head>
   <body>
     <div id=""terminal""></div>
     <script>
        var term = new Terminal();
        var agent = '%s';
        var lastbyte = 0;
        term.open(document.getElementById('terminal'));
        term.setOption('cursorBlink', true);
        term.focus();
    
        function poll() {
            var xhttp = new XMLHttpRequest();
            xhttp.onreadystatechange = function() {
                if (this.readyState == 4) {
                    if (this.status == 200) {
                        // First line is the byte offset in ascii
                        var n = this.responseText.indexOf('\n');
                        lastbyte = this.responseText.slice(0, n);

                        // Write the data to the terminal
                        term.write(this.responseText.slice(n+1));
                    }
                    
                    // Fetch again (even if there was an error) - we long poll
                    // This prevents session death, though is obviously fairly
                    // obnoxious to ignore all errors.
                    setTimeout(poll, 100);
                }
            };
            xhttp.open('GET', agent+'/rxstream', true);
            xhttp.setRequestHeader('Range', 'bytes='+lastbyte+'-');
            xhttp.timeout = 70000; // 70s for request life; agent should close after 60s
            xhttp.send();
        }
        poll();       
        
        // Keypress handler: no attempt at being clever here
        term.on('key', (key, ev) => {
            var xhttp = new XMLHttpRequest();
            xhttp.open('POST', agent+'/txstream', true);
            xhttp.send(key);
        });        

        // Paste handler: hope it's not too big!
        term.on('paste', (paste, ev) => {
            var xhttp = new XMLHttpRequest();
            xhttp.open('POST', agent+'/txstream', true);
            xhttp.send(paste);
        });        

     </script>
   </body>
 </html>";

// Set up rocky with a long timeout: 60s
api <- Rocky({ accessControl = true, allowUnsecure = false, strictRouting = false, timeout = 60 });

// If no auth is specified, tell the requester to get it; this will cause the browser to
// ask for username/password then re-fetch
api.onUnauthorized(function(context) {
    context.setHeader("WWW-Authenticate", "Basic realm=Authorization Required")
    context.send(401);
});

// Deal with checking username/password basic auth for all requests
api.authorize(function(context) {
    // Wrap this; any error (eg no auth header, wrong string length, bad base64 etc)
    // will cause an error which will immediately fail the authentication. This is
    // neater than trying to catch all the exceptions
    try {
        local auth = context.getHeader("Authorization");
        
        // We catch this one and return as *every* request without a header will hit
        // here and it results in a lot of spam
        if (auth == null) return false;
        
        // Check it's of the form "Basic XXX" where XXX is the base64 encoded value
        if (auth.slice(0,6).tolower() != "basic ") throw "bad header";
        
        // Decode the base64 part
        local userpass = http.base64decode(auth.slice(6)).tostring();

        // Check to see if the username/password matches; though this is slightly
        // over the top, we use the crypto constant time compare for safety
        if (crypto.equals(userpass, AUTH)) return true;
        
        server.log("Failed auth attempt: "+userpass);
    } catch(e) {
        // Something went wrong; log it
        server.log(e);
    }
    
    // If we got here, computer says no
    return false;
});

// Timeouts only hit the long poll; when this happens, just return a timeout.
// If the client is still there, they will re-issue the request
api.onTimeout(function(context) {
    // Remove from the waiters queue if it's there (it should be)
    for(local i=0; i<waiters.len(); i++) {
        if (context == waiters[i].context) {
            waiters.remove(i);
            break;
        }
    }
    
    // Send a generic timeout message
    context.send(408, { "message": "Agent Timeout" });
});

// Buffer of data received from device waiting to be picked up by browser(s)
rxbuffer <- "";
rxsize <- 100*1024;
rxoldest <- 0;
rxnewest <- 0;

// HTTP requests waiting for new serial data; when we get data from the device
// we push it to all waiters immediately
waiters <- [];

// Handle RX data from device
device.on("rxdata", function(v) {
    // Append to buffer
    rxbuffer += v;
    rxnewest += v.len();
    local rxlen = rxbuffer.len();
    
    // Trim buffer if it's oversize
    if (rxlen > rxsize) {
        rxbuffer = rxbuffer.slice(rxlen - rxsize);
        rxoldest += (rxlen - rxsize);
    }
    
    // We got new data; are there any sessions waiting for it?
    while(waiters.len()) {
        // Send the data to each session
        local session = waiters.pop();
        if (session.startat < rxoldest) session.startat = rxoldest;
        session.context.send(200, format("%d\n", rxnewest) + rxbuffer.slice(session.startat - rxoldest));
    }
})

// Set up the app's API
api.get("/", function(context) {
   // Root request: return the JS client
   local url = http.agenturl();
   context.send(200, format(HTML_STRING, url));
});

// Feed data to the terminal in the browser
api.get("/rxstream", function(context) {
    // Check range format and parse
    local range = context.getHeader("range");
    if (range != null && range.slice(0,6) == "bytes=") {
        local startat = range.slice(6).tointeger();
        
        // Work out what to send; startat bigger than rxnewest is generally only
        // when the agent has been restarted and a new request comes in
        if (startat < rxoldest) startat = rxoldest;
        if (startat > rxnewest) startat = rxnewest;

        if (debug) server.log(format("startat = %d, buffer = %d-%d", startat, rxoldest, rxnewest));

        // If there's no data, just hang for up to a minute until there is;
        // Rocky deals with this timeout, the client will just get sent a 408
        // after 60s and the client will re-issue the request
        if (rxnewest == startat) {
            if (debug) server.log("Pushing to waiters queue");
            waiters.push({ "context":context, "startat":startat });
            return;
        }
        
        // Otherwise, return now with the new data
        if (debug) server.log(format("sending %d bytes", rxbuffer.len() - (startat-rxoldest)));
        context.send(200, format("%d\n", rxnewest) + rxbuffer.slice(startat - rxoldest));
        return;
    }
    
    context.send(400, "Bad range");
});

// Data from the web client - keypresses or pastes - arrives here
// We just send it to the device
api.post("/txstream", function(context) {
    device.send("txdata", context.req.body);
    context.send(200, "");
});

// Print the number of open sessions every minute if debug is enabled
function print_sessions() {
    server.log("open sessions "+waiters.len());
    imp.wakeup(60, print_sessions);
}
if (debug) print_sessions();
