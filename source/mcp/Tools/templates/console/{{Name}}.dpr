program {{Name}};

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

begin
  try
    Writeln('Hello from {{Name}}');
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
