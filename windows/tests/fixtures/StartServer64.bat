@echo off
cd /D "%~dp0"
setlocal enableextensions

:loop
.\jre64\bin\java.exe -Djava.awt.headless=true -Xms16g -Xmx16g -XX:+UseZGC -Djava.library.path=natives/;natives/win64/;. -cp java/istack-commons-runtime.jar;java/jassimp.jar;java/javacord-2.0.17-shaded.jar;java/javax.activation-api.jar;java/jaxb-api.jar;java/jaxb-runtime.jar;java/lwjgl.jar;java/lwjgl-natives-windows.jar;java/sqlite-jdbc.jar;java/uncommons-maths-1.2.3.jar;java/zombie.jar zombie.network.GameServer -statistic 0 %*
if not "%errorlevel%"=="0" goto loop

endlocal
