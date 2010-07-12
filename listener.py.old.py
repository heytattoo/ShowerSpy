#!/usr/bin/env python
import serial, time, sys
from datetime import datetime

# Specify a datalog file
LOGFILENAME = "showerdatalog.csv"
# open our datalogging file
logfile = None
try:
	logfile = open(LOGFILENAME, 'r+')
except IOError:
    # didn't exist yet
    logfile = open(LOGFILENAME, 'w+')
    logfile.write("#Datetime, temperature\n");
    logfile.flush()

# Open the serial port connection to the XBee
SERIALPORT = "/dev/ttyUSB0"    # the com/serial port the XBee is connected to
BAUDRATE = 38400      # the baud rate we talk to the xbee
ser = serial.Serial(SERIALPORT, BAUDRATE)
ser.open()
ser.flushInput()

HISTORYLENGTH = 6
WARMINGCHANGE = 1.5
COOLINGCHANGE = -1.5
BUFFERINITVALUE = -99.0

tHistory = [BUFFERINITVALUE]*HISTORYLENGTH

while True:
	# Wait for incoming data
	try:
		t = float(ser.readline())
	except ValueError:
		# Didn't find a number; sensor is still initializing
		print 'initializing...'
		continue

	# Record current time
	dtNow = datetime.today()
	
	# Write temperature to log file
	logfile.write(dtNow.strftime("%d %B %Y %H:%M:%S,") + str(t) + "\n")
	logfile.flush() 
	
	# Figure out if the sensor is warming up (start of a shower) or 
	# cooling down (end of a shower)
	tHistory.insert(0,t)
	oldt = tHistory.pop()
	if oldt == BUFFERINITVALUE:
		# haven't filled the history buffer; can't tell if we're warming or not
		print 'filling history buffer...'
		continue
	
	delta = t - oldt
	if delta > WARMINGCHANGE:
		print "getting warmer at ", dtNow
	elif delta < COOLINGCHANGE:
		print "getting cooler at ", dtNow


