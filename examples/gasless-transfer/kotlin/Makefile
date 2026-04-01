JAVA_HOME ?= /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home

.PHONY: all build run clean

all: run

build:
	JAVA_HOME=$(JAVA_HOME) ./gradlew build -x test

run: build
	JAVA_HOME=$(JAVA_HOME) ./gradlew run

clean:
	JAVA_HOME=$(JAVA_HOME) ./gradlew clean
