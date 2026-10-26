package com.example.ordermanager.exception;

public class InvalidOrderStateException extends RuntimeException {

    public InvalidOrderStateException(String message) {
        super(message);
    }

    public InvalidOrderStateException(String currentState, String targetState) {
        super(String.format(
                "No se puede pasar de estado %s a %s",
                currentState, targetState
        ));
    }
}
