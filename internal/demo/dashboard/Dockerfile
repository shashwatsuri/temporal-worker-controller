FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG VITE_API_BASE_URL
ARG VITE_LOCAL_DEMO_MODE=false
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_LOCAL_DEMO_MODE=$VITE_LOCAL_DEMO_MODE
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
