FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY}
COPY Gateway.csproj ./
RUN dotnet restore Gateway.csproj
COPY . ./
RUN dotnet publish Gateway.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /out ./
ENV ASPNETCORE_ENVIRONMENT=Production
EXPOSE 8080
ENTRYPOINT ["dotnet", "Gateway.dll"]
