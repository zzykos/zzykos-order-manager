package com.example.ordermanager.controller;

import com.example.ordermanager.dto.AddItemRequest;
import com.example.ordermanager.dto.CreateOrderRequest;
import com.example.ordermanager.model.Order;
import com.example.ordermanager.model.OrderStatus;
import com.example.ordermanager.service.OrderService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    @GetMapping
    public ResponseEntity<List<Order>> getAllOrders() {
        return ResponseEntity.ok(service.getAllOrders());
    }

    @GetMapping("/status/{status}")
    public ResponseEntity<List<Order>> getOrdersByStatus(@PathVariable OrderStatus status) {
        return ResponseEntity.ok(service.getOrdersByStatus(status));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> getOrderById(@PathVariable Long id) {
        return ResponseEntity.ok(service.getOrderById(id));
    }

    @PostMapping
    public ResponseEntity<Order> createOrder(@Valid @RequestBody CreateOrderRequest request) {
        Order created = service.createOrder(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(created);
    }

    @PostMapping("/{id}/items")
    public ResponseEntity<Order> addItem(
            @PathVariable Long id,
            @Valid @RequestBody AddItemRequest request) {
        return ResponseEntity.ok(service.addItem(id, request));
    }

    @PutMapping("/{id}/confirm")
    public ResponseEntity<Order> confirmOrder(@PathVariable Long id) {
        return ResponseEntity.ok(service.confirmOrder(id));
    }

    @PutMapping("/{id}/ship")
    public ResponseEntity<Order> shipOrder(@PathVariable Long id) {
        return ResponseEntity.ok(service.shipOrder(id));
    }

    @PutMapping("/{id}/deliver")
    public ResponseEntity<Order> deliverOrder(@PathVariable Long id) {
        return ResponseEntity.ok(service.deliverOrder(id));
    }

    @PutMapping("/{id}/cancel")
    public ResponseEntity<Order> cancelOrder(@PathVariable Long id) {
        return ResponseEntity.ok(service.cancelOrder(id));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> deleteOrder(@PathVariable Long id) {
        service.deleteOrder(id);
        return ResponseEntity.noContent().build();
    }
}
