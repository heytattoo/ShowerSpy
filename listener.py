#!/usr/bin/env python
import serial, time, sys, string
from datetime import datetime
import platform

# Specify a datalog file
LOGFILENAME = "showerdatalog.csv"
# open our datalogging file
logfile = None
try:
	logfile = open(LOGFILENAME, 'r+') # if this doesn't throw an error, the file exists.
	logfile.close()
	logfile = open(LOGFILENAME, 'a') # assumes it's formatted correctly, and just append data
except IOError:
    # didn't exist yet
    logfile = open(LOGFILENAME, 'w+')
    logfile.write("#Datetime, temperature\n");
    logfile.flush()

# Open the serial port connection to the XBee

if (platform.system() == 'Darwin'):
  SERIALPORT = "/dev/tty.usbserial-A700eXpG"
else:
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
	s = ser.readline()
	s = string.rstrip(s,"\n")
	if s.find("TEMP:") != -1:
		dtNow = datetime.today()
		s = string.lstrip(s,"TEMP: ")
		# Write temperature to log file
		logfile.write(dtNow.strftime("%d %B %Y %H:%M:%S,") + s + "\n")
		logfile.flush()
		print "Logged temperature. ", s	
	elif s.find("ShowerOn?") != -1:
		print s, "\n"
	elif s.find("NUMBER OF SHOWERS?:") != -1:
		print s
