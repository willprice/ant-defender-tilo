#include <stdio.h>
#include <platform.h>

out port cled0 = PORT_CLOCKLED_0;
out port cled1 = PORT_CLOCKLED_1;
out port cled2 = PORT_CLOCKLED_2;
out port cled3 = PORT_CLOCKLED_3;
out port cledG = PORT_CLOCKLED_SELG;
out port cledR = PORT_CLOCKLED_SELR;
in port  buttons = PORT_BUTTON;
out port speaker = PORT_SPEAKER;

typedef enum { clockwise, anticlockwise } Direction;
typedef enum { false, true } bool;
typedef int Position;

//DISPLAYS an LED pattern in one quadrant of the clock LEDs
int showLED(out port p, chanend fromVisualiser) {
    unsigned int lightUpPattern;
    while (1) {
        fromVisualiser :> lightUpPattern; //read LED pattern from visualiser process
        p <: lightUpPattern;              //send pattern to LEDs
    }
    return 0;
}

int calculate_led_position(int i, int j, Position user_position, Position attacker_position, int quadrant_index) {
    return j*(user_position/3==quadrant_index) + i*(attacker_position/3==quadrant_index);
}
//PROCESS TO COORDINATE DISPLAY of LED Ants
void visualiser(chanend fromUserAnt, chanend fromAttackerAnt, chanend toQuadrant0, chanend toQuadrant1, chanend toQuadrant2, chanend toQuadrant3) {
    Position userAntToDisplay = 11;
    Position attackerAntToDisplay = 5;
    int i, j;
    cledR <: 1;
    while (1) {
        select {
        case fromUserAnt :> userAntToDisplay:
            break;
        case fromAttackerAnt :> attackerAntToDisplay:
            break;
        }
        // LED register:
        //e.g. value 0b0cba0000
        // cba are the LEDs on your quadrants.
        j = 0b10000<<(userAntToDisplay%3);
        i = 0b10000<<(attackerAntToDisplay%3);
        toQuadrant0 <: calculate_led_position(i, j, userAntToDisplay, attackerAntToDisplay, 0);
        toQuadrant1 <: calculate_led_position(i, j, userAntToDisplay, attackerAntToDisplay, 1);
        toQuadrant2 <: calculate_led_position(i, j, userAntToDisplay, attackerAntToDisplay, 2);
        toQuadrant3 <: calculate_led_position(i, j, userAntToDisplay, attackerAntToDisplay, 3);
    }
}

//PLAYS a short sound (pls use with caution and consideration to other students in the labs!)
void playSound(unsigned int wavelength, out port speaker) {
    timer  tmr;
    int time, isOn = 1;
    tmr :> time;
    for (int i=0; i<11; i++) {
        isOn = !isOn;
        time += wavelength;
        tmr when timerafter(time) :> void;
        speaker <: isOn;
    }
}

//READ BUTTONS and send to userAnt
void buttonListener(in port buttons, out port spkr, chanend toUserAnt) {
    int button_pattern;
    while (1) {
        buttons when pinsneq(0b1111) :> button_pattern;   // check if some buttons are pressed
        playSound(2*100*1000, spkr);   // play sound
        toUserAnt <: button_pattern;            // send button pattern to userAnt
    }
}

//WAIT function
void waitMoment() {
    timer tmr;
    uint waitTime;
    tmr :> waitTime;
    waitTime += 10000000;
    tmr when timerafter(waitTime) :> void;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
//  MOST RELEVANT PART OF CODE TO EXPAND FOR YOU
//
/////////////////////////////////////////////////////////////////////////////////////////

Position move_clockwise(Position initial_position) {
    if (initial_position == 11) { return 0; }
    else { return initial_position + 1; }
}
Position move_anticlockwise(Position initial_position) {
    if (initial_position == 0) { return 11; }
    else { return initial_position - 1; }
}

//DEFENDER PROCESS... The defender is controlled by this process userAnt,
//                    which has channels to a buttonListener, visualiser and controller
void userAnt(chanend fromButtons, chanend toVisualiser, chanend toController) {
    unsigned int userAntPosition = 11;       //the current defender position
    int buttonInput;                         //the input pattern from the buttonListener
    unsigned int attemptedAntPosition = userAntPosition;   //the next attempted defender position after considering button
    bool wasMoveValid;                       //the verdict of the controller if move is allowed
    toVisualiser <: userAntPosition;         //show initial position

    while (1) {
        toController :> wasMoveValid; // Wait for instruction from controller
        fromButtons :> buttonInput;
        if (buttonInput == 0b1110) {
            attemptedAntPosition = move_clockwise(userAntPosition);
        }
        if (buttonInput == 0b0111) {
            attemptedAntPosition = move_anticlockwise(userAntPosition);
        }
        toController <: attemptedAntPosition;
        toController :> wasMoveValid;
        if (wasMoveValid) {
            userAntPosition = attemptedAntPosition;
        }
        toVisualiser <: userAntPosition;
    }
}

Direction change_direction(Direction direction) {
    switch(direction) {
    case clockwise:
        return anticlockwise;
        break;
    case anticlockwise:
        return clockwise;
        break;
    }
}
//ATTACKER PROCESS... The attacker is controlled by this process attackerAnt,
//                    which has channels to the visualiser and controller
void attackerAnt(chanend toVisualiser, chanend toController) {
    int moveCounter = 0;                       //moves of attacker so far
    Position attackerAntPosition = 5;      //the current attacker position
    Position attemptedAntPosition = attackerAntPosition;         //the next attempted  position after considering move direction
    Direction currentDirection = clockwise;                  //the current direction the attacker is moving
    int moveForbidden = 0;                     //the verdict of the controller if move is allowed
    toVisualiser <: attackerAntPosition;       //show initial position

    while (1) {
        waitMoment();
        toController :> moveForbidden; // Wait for instruction from controller
        switch(currentDirection) {
        case clockwise:
            attemptedAntPosition = move_clockwise(attackerAntPosition);
            break;
        case anticlockwise:
            attemptedAntPosition = move_anticlockwise(attackerAntPosition);
            break;
        }
        bool wasValidMove;
        toController <: attemptedAntPosition;
        toController :> wasValidMove;
        if (wasValidMove) {
            attackerAntPosition = attemptedAntPosition;
        } else {
            currentDirection = change_direction(currentDirection);
        }
        toVisualiser <: attackerAntPosition;
    }
}

bool is_move_valid(Position attempted_move_position, Position other_ant_location) {
    if (attempted_move_position == other_ant_location) return false;
    return true;
}
//COLLISION DETECTOR... the controller process responds to "permission-to-move" requests
//                      from attackerAnt and userAnt. The process also checks if an attackerAnt
//                      has moved to LED positions I, XII and XI.
void controller(chanend attackerChannel, chanend userChannel) {
    Position lastReportedUserAntPosition = 11;      //position last reported by userAnt
    Position lastReportedAttackerAntPosition = 5;   //position last reported by attackerAnt
    unsigned int attempt = 0;
    int go = 1;
    attackerChannel <: go;
    userChannel <: go;
    userChannel :> attempt;                                //start game when user moves
    userChannel <: 1;                                      //forbid first move
    while (1) {
        select {
        case attackerChannel :> attempt:
            lastReportedAttackerAntPosition = attempt;
            attackerChannel <: is_move_valid(attempt, lastReportedUserAntPosition);
            break;
        case userChannel :> attempt:
            lastReportedUserAntPosition = attempt;
            userChannel <: is_move_valid(attempt, lastReportedAttackerAntPosition);
            break;
        }
        attackerChannel <: 1;
        userChannel <: 1;
    }
}

//MAIN PROCESS defining channels, orchestrating and starting the processes
int main(void) {
    chan buttonsToUserAnt,         //channel from buttonListener to userAnt
    userAntToVisualiser,      //channel from userAnt to Visualiser
    attackerAntToVisualiser,  //channel from attackerAnt to Visualiser
    attackerAntToController,  //channel from attackerAnt to Controller
    userAntToController;      //channel from userAnt to Controller
    chan quadrant0,quadrant1,quadrant2,quadrant3; //helper channels for LED visualisation

    par {
        //PROCESSES FOR YOU TO EXPAND
        on stdcore[1]: userAnt(buttonsToUserAnt,userAntToVisualiser,userAntToController);
        on stdcore[2]: attackerAnt(attackerAntToVisualiser,attackerAntToController);
        on stdcore[3]: controller(attackerAntToController, userAntToController);

        //HELPER PROCESSES
        on stdcore[0]: buttonListener(buttons, speaker,buttonsToUserAnt);
        on stdcore[0]: visualiser(userAntToVisualiser,attackerAntToVisualiser,quadrant0,quadrant1,quadrant2,quadrant3);
        on stdcore[0]: showLED(cled0,quadrant0);
        on stdcore[1]: showLED(cled1,quadrant1);
        on stdcore[2]: showLED(cled2,quadrant2);
        on stdcore[3]: showLED(cled3,quadrant3);
    }
    return 0;
}
