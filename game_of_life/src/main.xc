// COMS20001 - Cellular Automaton Farm

#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include "pgmIO.h"
#include "i2c.h"

#define  IMHT 64                        //image height
#define  IMWD 64                        //image width

#define infname "64x64.pgm"     //put your input image path here
#define outfname "testout.pgm"           //put your output image path here

#define numberOfWorkers 8
#define workerHeight (IMHT/numberOfWorkers)

#define ALIVE 255
#define DEAD 0

typedef unsigned char uchar;             //using uchar as shorthand

on tile[0] : port p_scl = XS1_PORT_1E;   //interface ports to orientation
on tile[0] : port p_sda = XS1_PORT_1F;

on tile[0] : in port hardwareButtons = XS1_PORT_4E;
on tile[0] : out port leds = XS1_PORT_4F;

#define FXOS8700EQ_I2C_ADDR 0x1E         //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6

//TIMING INTERFACE
typedef interface timerInterface {
    void start();
    void stopAndPrint();
    double stopAndReturn();
} timerInterface;

//USES TIMIMG INTERFACE TO ACT AS A STOPWATCH FROM ANYWHERE IN THE PROGRAM
void timerManager(server timerInterface timerI) {
    uint time0, time1, timestampDifference, timeTaken_roundedMinutes;
    double timeTaken, timeTaken_ms, timeTaken_s, timeTaken_secondsLeftOver;
    uint overflowCount;
    uint interval = 1E9;
    timer t;

    while(1){
        select {
            case timerI.start() :
                t :> time0;
                overflowCount = 0;
                break;
            case timerI.stopAndPrint() :
                t:> time1;
                if (time1<time0) timestampDifference = time1-time0+4294967295;
                else timestampDifference = time1-time0;
                timeTaken = (overflowCount*(double)interval+timestampDifference);
                timeTaken_ms = timeTaken/1000/(double)XS1_TIMER_MHZ;
                timeTaken_s = timeTaken_ms/1000;
                timeTaken_roundedMinutes = (timeTaken_s/60);
                timeTaken_secondsLeftOver = timeTaken_s-timeTaken_roundedMinutes*60;
                if (timeTaken_s>120) printf("Timer stopped\nTime taken: %d minutes %f seconds\n", timeTaken_roundedMinutes, timeTaken_secondsLeftOver);
                else if (timeTaken_s>2) printf("Timer stopped\nTime taken: %f seconds\n", timeTaken_s);
                else printf("Timer stopped\nTime taken: %f milliseconds\n", timeTaken_ms);
                break;
            case timerI.stopAndReturn() -> double timeTaken_s:
                t :> time1;
                if (time1<time0) timestampDifference = time1-time0+4294967295;
                else timestampDifference = time1-time0;
                timeTaken_s = (overflowCount*(double)interval+timestampDifference)/(double)XS1_TIMER_MHZ/1E6;
                break;
            case t when timerafter(time0+interval) :> time0:    //will start counting overruns before stopwatch starts, but stopwatch resets the overrun counter, so is fine.
                overflowCount++;
                break;
        }
    }
}

//RECOGNISES BUTTON INPUT
void buttonInput(in port hardwareButtons, chanend distCh) {
    uchar buttonPressed;
    while (1) {
        hardwareButtons when pinseq(15)  :> buttonPressed;    // check that no button is pressed
        hardwareButtons when pinsneq(15) :> buttonPressed;    // check if some buttons are pressed
        if ((buttonPressed==13) || (buttonPressed==14)) {     // if either button is pressed
            distCh <: buttonPressed;                          // send button pattern
        }
    }
}

//DISPLAYS LED OUTPUT
void ledOutput(out port led, chanend distCh) {
    int pattern;                       //1st bit...separate green LED 2nd bit...blue LED 3rd bit...green LED 4th bit...red LED
    while (1) {
        distCh :> pattern;             //receive new pattern from visualiser
        led <: pattern;                //send pattern to LED port
    }
}

//READ IMAGE FROM PGM FILE AND BIT-PACK IT INTO ARRAY TO SEND TO WORKERS
void DataInStream(chanend distCh, chanend workerChanArray[8]) {
    int res;
    uchar line[ IMWD ];
    printf( "DataInStream: Start...\n" );
    uchar prevPix = 0;
    uchar bitPix;   //for the byte with one correct bit in it
    uchar newPix;
    uchar trigger;

    //Open PGM file
    res = _openinpgm( infname, IMWD, IMHT );
    if( res ) {
        printf( "DataInStream: Error openening %s\n.", infname );
        return;
    }

    //Read image line-by-line and send byte by byte to channel distCh
    distCh :> trigger;                  // triggers processing
    for( int y = 0; y < IMHT; y++ ) {   //read in line
        _readinline( line, IMWD );
        for(int x = 0; x < IMWD; x++){  //bitpack each line
           // printf("-%4.1d ", line[ x ]);
            bitPix = ((line[x] & 1) << (7-(x%8)));
            newPix = (bitPix | prevPix);
            prevPix = newPix;
            if((x+1)%8 == 0){           //when full byte has been bitpacked
                for(int i = 0; i < 8; i++){
                    if(y/workerHeight < i+1){   //deciding which worker to send to
                        workerChanArray[i] <: newPix;
                        prevPix = 0;
                        break;
                    }
                }
            }
        }
        //printf("\n");
    }

    distCh <: (uchar)1;
    //Close PGM image file
    _closeinpgm();
    //printf( "DataInStream: Done...\n" );
    return;
}

//FARMS ALL WORKER THREADS AND CO-ORDINATES ALL OTHER THREADS
void distributor(chanend buttonCh, chanend dataInCh, chanend dataOutCh, chanend orientCh, chanend LEDCh, client timerInterface timerI, chanend workerChArray[]){
    uchar buttonPressed;
    int tilted=0;
    int roundCounter = 0;
    double timeTaken;
    uchar numberOfLiveCellsInWorkerArray[8], totalNumberOfLiveCells;
    uchar trigger;
    uchar pixel;
    printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
    printf( "\nPress button to start reading and processing...\n" );

    //waiting for left button to be pressed to import the image and start processing
    do{
        buttonCh :> buttonPressed;
    }while(buttonPressed != 14);
    dataInCh <: (uchar)1; //trigger data in
    LEDCh <: 0b0100;      //light green LED
    dataInCh :> trigger;
    LEDCh <: 0b0000;      //switch off LED
    timerI.start();
    for (int i = 0; i<100; i++){   //iterate through 100 rounds

        select {
            case orientCh :> tilted :
                if (tilted == 1) {
                    //count the number of live cells
                    timeTaken = timerI.stopAndReturn();
                    totalNumberOfLiveCells = 0;
                    for(int i = 0; i<8; i++){
                        workerChArray[i] <: (uchar)2;
                    }
                    for(int i = 0; i<8; i++){
                        workerChArray[i] :> numberOfLiveCellsInWorkerArray[i];
                    }
                    for(int i = 0; i<8; i++){
                        totalNumberOfLiveCells += numberOfLiveCellsInWorkerArray[i];
                    }
                    LEDCh <: 0b1000;    //light red LED
                    printf("Number of rounds processed: %d  Time taken since reading in File: %f  Number of live cells: %d\n", roundCounter, timeTaken, totalNumberOfLiveCells);
                    orientCh :> tilted;
                }
                break;

            case buttonCh :> buttonPressed :
                if(buttonPressed == 13) {           //if the right button is pressed, store the image
                    LEDCh <: 0b0010;                //light blue LED
                    for(int i = 0; i<8; i++){
                        workerChArray[i] <: (uchar)1;
                    }
                    for(int j = 0; j<8; j++){       //for every worker, get the image from the worker and send it to dataOut
                        for(int y = 0; y < workerHeight; y++){
                            for(int x = 0; x < IMWD/8; x++){
                                workerChArray[j] :> pixel;
                                dataOutCh <: pixel;
                            }
                        }
                    }
                    dataOutCh :> trigger;
                    LEDCh <: 0b0000;  //switch off LED
                }
                break;

            default :      //process as normal providing board not tilted
                if(!tilted) {
                    for(int i = 0; i<8; i++){
                        workerChArray[i] <: (uchar)0;
                    }
                    if(roundCounter%2 == 0) LEDCh <: 0b0001;    //to flash the led
                    else LEDCh <: 0b0000;
                    roundCounter++;
                }
                break;
        }
    }
    timerI.stopAndPrint();
}

//APPLY GAME OF LIFE LOGIC TO THE BOARD
void worker(chanend prevWorkerCh, chanend nextWorkerCh, chanend distCh, chanend dataInCh, uchar id){
    uchar world[IMWD/8][workerHeight+2]; //1 for each extra top row and extra bottom row
    uchar newWorld[IMWD/8][workerHeight+2]; //need another grid to store the output grid, because otherwise there is a mix between old values and new values, which the next pixel looks at
    uchar trigger;
    uchar prevPix = 0;
    uchar bitPix;
    uchar newPix;
    uchar neighbours;
    uchar numberOfLiveCells;

    //receive section of board from dataIn
    for( int y = 1; y < workerHeight+1; y++ ) {
        for( int x = 0; x < IMWD/8; x++ ) {
            dataInCh :> world[x][y];
        }
    }

    while(1){
        distCh :> trigger;
        if(trigger == 0){

            if(id == 0){ // sends first
                for(int x = 0; x < IMWD/8; x++){
                    prevWorkerCh <: world[x][1];
                    nextWorkerCh <: world[x][workerHeight];
                }
                for(int x = 0; x < IMWD/8; x++){
                    prevWorkerCh :> world[x][0];
                    nextWorkerCh :> world[x][workerHeight+1];
                }
            }else if(id == 1){ //receive first
                for(int x = 0; x < IMWD/8; x++){
                    nextWorkerCh :> world[x][workerHeight+1];
                    prevWorkerCh :> world[x][0];
               }
               for(int x = 0; x < IMWD/8; x++){
                   nextWorkerCh <: world[x][workerHeight];
                   prevWorkerCh <: world[x][1];
               }
            }

            for( int y = 1; y < workerHeight+1; y++ ) {    //not looking at the initial row and last row, because not making changes to that
                for( int x = IMWD/8; x < 2*IMWD/8; x++ ) {
                    neighbours = 0;

                    for(int i = 0; i<8; i++){

                        neighbours = 0;

                        //count neighbours with bitwise logic
                        if (i == 0){

                            if(((world[(x-1)%(IMWD/8)][y-1]) & 1) == 1) neighbours++;
                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)-1))) != 0) neighbours++;

                            if(((world[(x-1)%(IMWD/8)][y]) & 1) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y]) & (1 << (7-(i%8)-1))) != 0) neighbours++;

                            if(((world[(x-1)%(IMWD/8)][y+1]) & 1) == 1) neighbours++;
                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)-1))) != 0) neighbours++;

                        }else if(i == 7){

                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[(x+1)%(IMWD/8)][y-1]) & (1 << 7)) != 0) neighbours++;

                            if(((world[x%(IMWD/8)][y]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[(x+1)%(IMWD/8)][y]) & (1 << 7)) != 0) neighbours++;

                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[(x+1)%(IMWD/8)][y+1]) & (1 << 7)) != 0) neighbours++;

                        }else{

                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y-1]) & (1 << (7-(i%8)-1))) != 0) neighbours++;

                            if(((world[x%(IMWD/8)][y]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y]) & (1 << (7-(i%8)-1))) != 0) neighbours++;

                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)+1))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)))) != 0) neighbours++;
                            if(((world[x%(IMWD/8)][y+1]) & (1 << (7-(i%8)-1))) != 0) neighbours++;
                        }

                        //apply Game of Life rules based on neighbour count
                        if (neighbours == 3){
                            bitPix = (1 << (7-(i%8)));
                            newPix = (bitPix | prevPix);
                            prevPix = newPix;
                        }else if(((world[x%(IMWD/8)][y]) & (1 << (7-(i%8)))) && (neighbours == 2)){
                            bitPix = (1 << (7-(i%8)));
                            newPix = (bitPix | prevPix);
                            prevPix = newPix;
                        }else{
                            bitPix = (0 << (7-(i%8)));
                            newPix = (bitPix | prevPix);
                            prevPix = newPix;
                        }

                        if((i+1)%8 == 0){
                            newWorld[x%(IMWD/8)][y] = newPix;
                            prevPix = 0;
                        }
                    }
                }
            }

            //copy the newWorld into world, for next iteration compare to
            for( int y = 0; y < workerHeight+2; y++ ) {
                for( int x = 0; x < IMWD/8; x++ ) {
                    world[x][y] = newWorld[x][y];
                }
            }
        }else if(trigger == 1){ // export world
            for( int y = 1; y < workerHeight+1; y++ ) {
                for( int x = 0; x < IMWD/8; x++ ) {
                    distCh <: world[x][y];
                }
            }
        }else if(trigger == 2){ //computations for pause then wait for unpause
            numberOfLiveCells = 0;
            for( int y = 1; y < workerHeight+1; y++ ) {
                for( int x = 0; x < IMWD; x++ ) {
                    if((world[x/8][y] & (1 << (7-(x%8)))) != 0) numberOfLiveCells++;
                }
            }
            distCh <: numberOfLiveCells;
        }
    }
}

//UNPACK BOARD AND EXPORT TO PGM
void DataOutStream(chanend distCh) {
    int res;
    uchar bitLine[ IMWD/8 ];
    uchar line[ IMWD ];

    //Open PGM file
    printf( "DataOutStream: Start...\n" );
    res = _openoutpgm( outfname, IMWD, IMHT );
    if( res ) {
        printf( "DataOutStream: Error opening %s\n.", outfname );
        return;
    }

    while(1) {
        //stores the incoming array
        for( int y = 0; y < IMHT; y++ ) {
            for( int x = 0; x < IMWD/8; x++ ) {
                distCh :> bitLine[x];
            }

            for(int i = 0; i < IMWD; i++){
                if((bitLine[i/8]  & (1 << (7-(i%8)))) >> (7-(i%8)) == 1 ) line[i] = ALIVE;
                else line[i] = DEAD;
                //printf( "-%4.1d ", line[ i ] );
            }

            _writeoutline( line, IMWD );    //stores a whole line into the file
            //printf( "DataOutStream: Line written...\n" );
        }

        //Close the PGM image
        _closeoutpgm();
        distCh <: (uchar)1; // data out finished trigger
        printf( "DataOutStream: Done...\n" );
    }
}

//LISTEN FOR BOARD ORIENTATION
void orientation( client interface i2c_master_if i2c, chanend distCh) {
    i2c_regop_res_t result;
    char status_data = 0;
    int tilted = 0;
    int prevTilted = tilted;

    // Configure FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }
  
    // Enable FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }

    //Probe the orientation x-axis forever
    while (1) {
        //check until new orientation data is available
        do {
            status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
        } while (!status_data & 0x08);

        //get new x-axis tilt value
        int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);
        if(x>30) tilted = 1;
        else tilted = 0;
        if(tilted != prevTilted) {
            distCh <: tilted;
            prevTilted = tilted;
        }
    }
}

//START ALL THREADS
int main(void) {
    i2c_master_if i2c[1];               //interface to orientation
    chan buttonDistCh, distDataInCh, distDataOutCh, distOrientCh, distLEDCh;
    chan workerDataInChanArray[8];
    chan workerDistChanArray[8];
    chan workerWorkerChanArray[8];
    timerInterface timerI;

    par {
        on tile[0] : i2c_master(i2c, 1, p_scl, p_sda, 10);   //server thread providing orientation data
        on tile[0] : orientation(i2c[0],distOrientCh);       //client thread reading orientation data
        on tile[0] : buttonInput(hardwareButtons, buttonDistCh);
        on tile[0] : ledOutput(leds, distLEDCh);
        on tile[0] : DataInStream(distDataInCh, workerDataInChanArray);    //thread to read in a PGM image
        on tile[1] : DataOutStream(distDataOutCh);       //thread to write out a PGM image
        on tile[1] : distributor(buttonDistCh, distDataInCh, distDataOutCh, distOrientCh, distLEDCh, timerI, workerDistChanArray);  //thread to coordinate work on image
        on tile[1] : timerManager(timerI);

        par(int i = numberOfWorkers; i<3*numberOfWorkers/2; i++){
            on tile[0] : worker(workerWorkerChanArray[(i-1)%numberOfWorkers], workerWorkerChanArray[i%numberOfWorkers], workerDistChanArray[i%numberOfWorkers], workerDataInChanArray[i%numberOfWorkers], (i%2));
        }
        par(int i = 3*numberOfWorkers/2; i<2*numberOfWorkers; i++){
            on tile[1] : worker(workerWorkerChanArray[(i-1)%numberOfWorkers], workerWorkerChanArray[i%numberOfWorkers], workerDistChanArray[i%numberOfWorkers], workerDataInChanArray[i%numberOfWorkers], (i%2));
        }
    }
    return 0;
}
