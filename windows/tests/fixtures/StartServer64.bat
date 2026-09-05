@echo off
SETLOCAL ENABLEEXTENSIONS
SET PZ_CLASSPATH=java/istack-commons-runtime.jar;java/jassimp.jar;java/javacord-2.0.17-shaded.jar;java/javax.activation-api.jar;java/jaxb-api.jar;java/jaxb-runtime.jar;java/lwjgl.jar;java/lwjgl-natives-windows.jar;java/sqlite-jdbc.jar;java/uncommons-maths-1.2.3.jar;java/
".\jre64\bin\java.exe" -Djava.awt.headless=true -Dzomboid.steam=1 -Dzomboid.znetlog=1 -XX:+UseZGC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow -Xms16g -Xmx16g -Djava.library.path=natives/;natives/win64/;. -cp %PZ_CLASSPATH% zombie.network.GameServer -statistic 0 %1 %2 %3 %4 %5 %6 %7 %8
PAUSE
