
/*
Reads a temperature value from a DS18B20 1-Wire temperature sensor and 
sends the result to a software serial port.

TO DO LIST:
-- Email DallasTemperature guy about conversionDelay bug

*/

#include <NewSoftSerial.h>
#include <OneWire.h>
#include <DallasTemperature.h>
#include <ShowerLog.h>
#include <avr/interrupt.h>
#include <avr/wdt.h>
#include <avr/sleep.h>

// **************************************************
// **** DEFINE statements
#define ONE_WIRE_BUS           7      // Location of one-wire bus data pin
#define DS18B20_RESOLUTION     11      // can be 9-, 10-, 11-, or 12-bit
#define XBEE_BAUDRATE          38400  // Both XBee modules must be pre-configured 
																			// to run at this baud rate 
#define XBEE_RX_PIN            3
#define XBEE_TX_PIN            2
#define DEVICE_INDEX           0
#define NUM_CYCLES_PER_SAMPLE  1      // Number of 8-second periods you want to 
																			// pass before re-checking temperature 
#define XBEE_SLEEP_PIN         10
#define XBEE_WAKE_DELAY        14     // Time (in ms) to wait after the WAKE signal
																			// before talking to the XBee
#define DEBUG_LED_PIN          12
#define DEBUG_STARTUP_BLINKS   4      // Number of times the LED blinks in the setup() routine
#define DEBUG_LED_DWELL        400    // dwell time of LED blinking [ms]

#define RISING_HISTER					 2.5    // [degC] If the templog shows this much change over its span
																			// then a shower has started
#define RISING_RANGE					 5
																			
#define FALLING_HISTER				 1.0    // [degC] if the templog shows this much change over its span
																			// then a shower has ended
#define FALLING_RANGE					 30			// Look back this far into the sample history when trying to identify
																			// a post-shower cooling period.  @ ~10sec samples, 30 samples = 5min
																			
#define FALLING_TOOSTEEP_V		 1.5    
#define FALLING_TOOSTEEP_R		 6

#define CHIRP_PERIOD					 30    	// Wait this many samples between data chirps, unless in DEBUG mode.

#define DEBUG_MODE										// if defined, the unit will send debug info over the serial port at each sample

// **************************************************
// **** GLOBALS
NewSoftSerial xb(XBEE_RX_PIN, XBEE_TX_PIN); // RX, TX
OneWire oneWire(ONE_WIRE_BUS);
ShowerLog slog; // stores information on completed showers
FloatLog tlog; // stores information on previous temperature readings
DallasTemperature sensors(&oneWire);
DeviceAddress devAddr;
int cycleCount = NUM_CYCLES_PER_SAMPLE - 1; // Take the first sample immediately
bool flagWDT = TRUE;
byte ledState = 0;
bool showerOn = FALSE;
uint8_t showerDuration = 0;
uint16_t sampleCount = 0;

// **************************************************
// **** SETUP routine
void setup() {

	//**** Disable ADC to save power
	ADCSRA &= ~(1<<ADEN);

	//**** Set sleep mode to Power-down: 
	set_sleep_mode(SLEEP_MODE_PWR_DOWN);
	sleep_disable();

	//**** Set watchdog mode to a 8-second interval	
	// NOTE: actual period is about 9.89 seconds between samples
	cli(); // disable interrupts
	wdt_reset(); // reset WDT
	MCUSR &= ~(1<<WDRF); // clear Watchdog System Reset Flag
	// Start timed sequence
	WDTCSR |= (1<<WDCE) | (1<<WDE);
	// Set a new prescaler(time-out) value (~8 seconds).  
	// Also, enable System Reset and Interrupt Mode for the WDT
	WDTCSR = (1<<WDP3) | (1<<WDP0) | (1<<WDE) | (1<<WDIE);
	sei(); // re-enable interrupts

	//**** Set up the XBee
	pinMode(XBEE_SLEEP_PIN,OUTPUT); // Used for controlling the sleep state the XBee
	digitalWrite(XBEE_SLEEP_PIN,0); // Ensure the XBee is awake
	delay(XBEE_WAKE_DELAY); // Give it time to wake up
	xb.begin(XBEE_BAUDRATE); // Set up software serial communication over the XBee
	xb.println("");
	xb.println("Beginning temperature readings...");

	//**** Set up temperature sensor
	//Start the temperature library
	sensors.begin();
	//Find the device address of our sensor
	sensors.getAddress(devAddr,0);
	//Set lower resolution for faster operation
	sensors.setResolution(devAddr, DS18B20_RESOLUTION);

	//**** Confirm temperature sensor resolution
	xb.print("Sensor resolution: ");
	xb.println((int)sensors.getResolution(devAddr));
	xb.println("");

	digitalWrite(XBEE_SLEEP_PIN,1); // Put the XBee to sleep

	pinMode(DEBUG_LED_PIN,OUTPUT);

	for (uint8_t i=0;i<DEBUG_STARTUP_BLINKS;i++){
		digitalWrite(DEBUG_LED_PIN,0);
		delay(DEBUG_LED_DWELL);
		digitalWrite(DEBUG_LED_PIN,1);
		delay(DEBUG_LED_DWELL);
	}
	ledState = 1;
}

// **************************************************
// LOOP routine
void loop() {

	float t;

	if (flagWDT) {
		WDTCSR |= (1<<WDIE); // Re-enable WDT Interrupt Mode
		flagWDT=FALSE;
		cycleCount++;
		digitalWrite(DEBUG_LED_PIN,ledState=(ledState*-1)+1); // toggle the LED state
	}
	
	if (cycleCount == NUM_CYCLES_PER_SAMPLE){
		// time to take a sample
		sampleCount++;
		cycleCount = 0;
		slog.incrementAll(); //age all stored shower data
		if (showerOn) showerDuration++; // if shower is on, increment the current shower duration

		// +++
		sensors.requestTemperatures(); // Send the command to get temperatures
		t = sensors.getTempCByIndex(DEVICE_INDEX);
		// --- ~30ms

		// Add the current temperature to the log
		tlog.add(t);
		// Check current temperature against past temperatures.

		if (tlog.isWarming((float)RISING_HISTER, (uint8_t)RISING_RANGE) && !showerOn){
			// New shower!
			showerOn = TRUE;
			showerDuration = 0;
		} 
		else if (tlog.isCooling((float)FALLING_HISTER,
														(uint8_t)FALLING_RANGE,
														(uint8_t)FALLING_TOOSTEEP_R,
														(float)FALLING_TOOSTEEP_V)
														 && showerOn){
			// End of a shower!
			showerOn = FALSE;
			slog.add((uint8_t) tlog.get((uint8_t)FALLING_RANGE), showerDuration - FALLING_RANGE);
			showerDuration = 0;
		}	
    
		#ifdef DEBUG_MODE // In debug mode, chirp after every temperature sample
		sampleCount = (uint16_t)CHIRP_PERIOD;
		#endif

		// If time's up, send a chirp of shower data
		if (sampleCount == CHIRP_PERIOD) {
				// Time to send some data out over the Xbee (and 
				// hope someone is listening)
				sampleCount = 0; // reset the sample count
				
				digitalWrite(XBEE_SLEEP_PIN,0); // Wake XBee from sleep
				delay(XBEE_WAKE_DELAY); // Give the XBee time to wake up

				
				//****** Just send a short sample message ******
				#ifdef DEBUG_MODE
				
				xb.print("NUMBER OF SHOWERS?: ");
				xb.println((int)slog.numFilled());
				xb.print("TEMP: ");
				xb.println(t);
				xb.print("ShowerOn? ");
				xb.println(showerOn);
				#endif
				
				
				// **** send all stored data over the serial port ****
				xb.print("SS;"); // Start of data
				for (uint8_t i = 0; i<(int)slog.size(); i++) {
					xb.print((float)slog.getTemp(i));
					xb.print(',');
					xb.print((int)slog.getDuration(i));
					xb.print(',');
					xb.print((int)slog.getAge(i));
					xb.print(';');			
				} 
				xb.print((int)slog.checksum()); // send a checksum to allow receiver to varify packet
				xb.println(";FF"); // End of data
				

				digitalWrite(XBEE_SLEEP_PIN,1); // Put the XBee to sleep
					// --- ~19ms  
		}
	
	}
	
	sleep_mode(); // put the CPU to sleep
	// code will resume here when WDT expires (after ISR routine)

	
}
//****************************************************************  
// Watchdog Interrupt Service / is executed when  watchdog timed out
ISR(WDT_vect) {
	flagWDT=TRUE;  // set global flag
}




